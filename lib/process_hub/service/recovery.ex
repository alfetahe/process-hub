defmodule ProcessHub.Service.Recovery do
  @moduledoc """
  State-machine logic for the opt-in coordinator boot-recovery lifecycle.

  When `:auto_recovery` is enabled, the coordinator transitions through
  three states (`:recovery_pending → :recovering | :normal`) on start-up.
  This module owns the pure helpers used by the coordinator to drive that
  lifecycle:

  - parsing/validating the `:auto_recovery` config
  - deciding the next state given peer announcements and timer events
  - dispatching the peer-mode-exchange events
  - replaying the persisted registry into `Distributor.compose_start_operation/3`
  - emitting telemetry and dispatching the recovery hooks

  The coordinator stays the GenServer; this module is stateless aside from
  the data passed in.
  """

  require Logger

  alias ProcessHub.Constant.Event
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.LoggerService
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Hub

  use Event

  @default_recovery_window_ms 10_000
  @default_replay_timeout_ms 60_000

  @recovery_window_min 1_000
  @recovery_window_max 600_000
  @replay_timeout_min 1_000
  @replay_timeout_max 3_600_000

  @typedoc "Result of a recovery-replay run."
  @type replay_result() :: %{
          child_count: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          reason: :completed | :replay_timeout | :empty
        }

  @doc """
  Parses the `:auto_recovery` config field into a normalized map.

  Accepts the documented shapes:

    * `false` — disabled.
    * `true` — enabled with defaults.
    * `keyword()` — explicit `:recovery_window_ms` / `:replay_timeout_ms`.

  Returns `{:ok, recovery_config}` or `{:error, reason}` for out-of-range
  values. Unknown shapes return `{:error, :invalid_auto_recovery}` so the
  caller can decide whether to fall back to disabled or to refuse to
  start.
  """
  @spec parse_config(false | true | keyword() | term()) ::
          {:ok, Hub.recovery_config()}
          | {:error,
             :invalid_auto_recovery
             | {:invalid_auto_recovery, atom()}}
  def parse_config(false), do: {:ok, disabled_config()}

  def parse_config(true) do
    {:ok,
     %{
       enabled?: true,
       recovery_window_ms: @default_recovery_window_ms,
       replay_timeout_ms: @default_replay_timeout_ms
     }}
  end

  def parse_config(opts) when is_list(opts) do
    with {:ok, window} <-
           validate_int(
             Keyword.get(opts, :recovery_window_ms, @default_recovery_window_ms),
             @recovery_window_min,
             @recovery_window_max,
             :recovery_window_ms_out_of_range
           ),
         {:ok, replay} <-
           validate_int(
             Keyword.get(opts, :replay_timeout_ms, @default_replay_timeout_ms),
             @replay_timeout_min,
             @replay_timeout_max,
             :replay_timeout_ms_out_of_range
           ) do
      {:ok, %{enabled?: true, recovery_window_ms: window, replay_timeout_ms: replay}}
    end
  end

  def parse_config(_), do: {:error, :invalid_auto_recovery}

  @doc "Returns the disabled (default) config."
  @spec disabled_config() :: Hub.recovery_config()
  def disabled_config do
    %{
      enabled?: false,
      recovery_window_ms: @default_recovery_window_ms,
      replay_timeout_ms: @default_replay_timeout_ms
    }
  end

  defp validate_int(value, min, max, _err)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp validate_int(_value, _min, _max, err), do: {:error, {:invalid_auto_recovery, err}}

  @doc """
  Decides the next state given the current state and a peer-announce event.

  Returns one of:

    * `{:transition, :normal, :peer_normal}` — defer-to-peers path.
    * `:no_change` — peer announce does not change local state.

  Pure function. Coordinator carries out the actual transition and
  side-effects.
  """
  @spec compute_transition(Hub.recovery_state(), Hub.recovery_state()) ::
          {:transition, :normal, :peer_normal} | :no_change
  def compute_transition(:recovery_pending, :normal),
    do: {:transition, :normal, :peer_normal}

  def compute_transition(_local, _peer), do: :no_change

  @doc """
  Returns true if at least one peer is reported as `:normal`.

  Used by the window-elapsed handler to decide between the deferred path
  and the local-replay path.
  """
  @spec any_peer_normal?(%{node() => Hub.recovery_state()}) :: boolean()
  def any_peer_normal?(peers) when is_map(peers) do
    Enum.any?(peers, fn {_node, state} -> state == :normal end)
  end

  @doc """
  Dispatches `@event_recovery_state_query` to the given peer node(s).
  """
  @spec dispatch_query(Hub.t(), [node()] | :external) :: :ok
  def dispatch_query(%Hub{} = state, members) do
    members = normalize_members(members)

    Dispatcher.dispatch_event(
      state.procs.event_queue,
      @event_recovery_state_query,
      node(),
      %{members: members}
    )

    :ok
  end

  @doc """
  Dispatches `@event_recovery_state_announce` carrying `{node(), state}`
  to the given peer node(s).
  """
  @spec dispatch_announce(Hub.t(), [node()] | :external | :local) :: :ok
  def dispatch_announce(%Hub{} = state, members) do
    members = normalize_members(members)

    Dispatcher.dispatch_event(
      state.procs.event_queue,
      @event_recovery_state_announce,
      {node(), state.recovery_state},
      %{members: members}
    )

    :ok
  end

  defp normalize_members(:external), do: :external
  defp normalize_members(:local), do: :local
  defp normalize_members(:global), do: :global
  defp normalize_members(nodes) when is_list(nodes), do: nodes

  @doc """
  Dispatches the `recovery_state_changed` hook with full payload.
  """
  @spec dispatch_state_changed_hook(Hub.t(), atom(), atom(), atom()) :: :ok
  def dispatch_state_changed_hook(%Hub{} = state, from, to, reason) do
    HookManager.dispatch_hook(state.storage.hook, Hook.recovery_state_changed(), %{
      from: from,
      to: to,
      reason: reason,
      peers: state.recovery_peers
    })

    :ok
  end

  @doc """
  Runs the persisted-registry replay synchronously inside the calling
  process (the coordinator).

  Sequence:

    1. emit `:recovery_replay_started` telemetry,
    2. dispatch the `pre_recovery_replay` hook synchronously (blocking),
    3. iterate `ProcessRegistry.dump/1`,
    4. call `Distributor.compose_start_operation/3` once with all child specs,
    5. wait up to `replay_timeout_ms` for completion (best effort),
    6. emit `:recovery_replay_completed` telemetry,
    7. dispatch `post_recovery_replay` (async).

  Returns a `replay_result/0` summary that the coordinator uses to update
  state and dispatch the `recovery_state_changed` hook.

  Per-child failures during replay are logged at WARN and surface in the
  `failed` count; they never abort the replay loop. If `replay_timeout_ms`
  elapses before completion, the function returns with
  `reason: :replay_timeout`. Replay continues in the background.
  """
  @spec replay(Hub.t(), Hub.recovery_config()) :: replay_result()
  def replay(%Hub{} = state, %{replay_timeout_ms: replay_timeout_ms}) do
    started_at = System.monotonic_time(:millisecond)
    dump = ProcessRegistry.dump(state.hub_id)
    child_count = map_size(dump)

    emit_telemetry(:recovery_replay_started, %{child_count: child_count}, %{
      hub_id: state.hub_id
    })

    dispatch_blocking_hook(
      state.storage.hook,
      Hook.pre_recovery_replay(),
      %{hub_id: state.hub_id, child_count: child_count},
      replay_timeout_ms
    )

    {succeeded, failed, reason} =
      case child_count do
        0 ->
          {0, 0, :empty}

        _ ->
          execute_replay(state, dump, replay_timeout_ms, started_at)
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    emit_telemetry(
      :recovery_replay_completed,
      %{
        child_count: child_count,
        succeeded: succeeded,
        failed: failed,
        elapsed_ms: elapsed_ms
      },
      %{hub_id: state.hub_id, reason: reason}
    )

    HookManager.dispatch_hook(state.storage.hook, Hook.post_recovery_replay(), %{
      hub_id: state.hub_id,
      child_count: child_count,
      succeeded: succeeded,
      failed: failed,
      reason: reason
    })

    %{
      child_count: child_count,
      succeeded: succeeded,
      failed: failed,
      elapsed_ms: elapsed_ms,
      reason: reason
    }
  end

  defp execute_replay(state, dump, replay_timeout_ms, started_at) do
    child_specs =
      dump
      |> Enum.map(fn {_child_id, value} -> elem(value, 0) end)

    parent = self()
    ref = make_ref()

    {pid, mon_ref} =
      spawn_monitor(fn ->
        result =
          try do
            Distributor.compose_start_operation(state, child_specs, [
              {:auto_recovery_replay, true},
              {:awaitable, false},
              {:check_existing, false},
              {:disable_logging, true}
            ])
          rescue
            err -> {:error, err}
          end

        send(parent, {ref, result})
      end)

    elapsed = System.monotonic_time(:millisecond) - started_at
    remaining = max(replay_timeout_ms - elapsed, 0)

    receive do
      {^ref, {:ok, _operation}} ->
        Process.demonitor(mon_ref, [:flush])
        {length(child_specs), 0, :completed}

      {^ref, {:error, reason}} ->
        Process.demonitor(mon_ref, [:flush])

        LoggerService.warning(
          "Recovery replay returned error: @reason",
          %{"reason" => inspect(reason)},
          prefix: "Recovery"
        )

        {0, length(child_specs), :completed}

      {:DOWN, ^mon_ref, :process, ^pid, reason} ->
        LoggerService.warning(
          "Recovery replay task crashed: @reason",
          %{"reason" => inspect(reason)},
          prefix: "Recovery"
        )

        {0, length(child_specs), :completed}
    after
      remaining ->
        Process.demonitor(mon_ref, [:flush])

        LoggerService.warning(
          "Recovery replay timed out after @ms ms; continuing in background",
          %{"ms" => Integer.to_string(replay_timeout_ms)},
          prefix: "Recovery"
        )

        {0, length(child_specs), :replay_timeout}
    end
  end

  @doc """
  Dispatches a hook synchronously, awaiting each handler's reply. Each
  handler is wrapped in `try/catch` so a misbehaving handler can neither
  crash the coordinator nor (via the per-handler timeout) hang it past
  the overall `replay_timeout_ms`.

  Handlers are executed in registered order; per-handler timeouts are
  computed as the remaining slice of the total budget. A handler raising
  is logged at WARN and the dispatch continues to the next handler.
  """
  @spec dispatch_blocking_hook(:ets.tid(), HookManager.hook_key(), term(), pos_integer()) :: :ok
  def dispatch_blocking_hook(hook_table, hook_key, hook_data, total_timeout_ms) do
    handlers = HookManager.registered_handlers(hook_table, hook_key)
    started_at = System.monotonic_time(:millisecond)

    Enum.each(handlers, fn handler ->
      elapsed = System.monotonic_time(:millisecond) - started_at
      remaining = max(total_timeout_ms - elapsed, 0)

      run_handler_blocking(handler, hook_data, remaining)
    end)

    :ok
  end

  defp run_handler_blocking(_handler, _hook_data, 0) do
    LoggerService.warning(
      "Skipping recovery hook handler — total budget exhausted",
      %{},
      prefix: "Recovery"
    )

    :ok
  end

  defp run_handler_blocking(%HookManager{m: module, f: func, a: args} = handler, hook_data, timeout) do
    args = substitute_wildcard(args, hook_data)

    parent = self()
    ref = make_ref()

    {pid, mon_ref} =
      spawn_monitor(fn ->
        result =
          try do
            apply(module, func, args)
          rescue
            e -> {:__hook_raised__, e, __STACKTRACE__}
          catch
            kind, value -> {:__hook_caught__, kind, value, __STACKTRACE__}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, {:__hook_raised__, e, st}} ->
        Process.demonitor(mon_ref, [:flush])

        LoggerService.warning(
          "Recovery hook handler @id raised: @error",
          %{"id" => inspect(handler.id), "error" => Exception.format(:error, e, st)},
          prefix: "Recovery"
        )

        :ok

      {^ref, {:__hook_caught__, kind, value, _st}} ->
        Process.demonitor(mon_ref, [:flush])

        LoggerService.warning(
          "Recovery hook handler @id caught @kind: @value",
          %{
            "id" => inspect(handler.id),
            "kind" => Atom.to_string(kind),
            "value" => inspect(value)
          },
          prefix: "Recovery"
        )

        :ok

      {^ref, _ok} ->
        Process.demonitor(mon_ref, [:flush])
        :ok

      {:DOWN, ^mon_ref, :process, ^pid, reason} when reason != :normal ->
        LoggerService.warning(
          "Recovery hook handler @id task crashed: @reason",
          %{"id" => inspect(handler.id), "reason" => inspect(reason)},
          prefix: "Recovery"
        )

        :ok
    after
      timeout ->
        Process.demonitor(mon_ref, [:flush])
        Process.exit(pid, :kill)

        LoggerService.warning(
          "Recovery hook handler @id timed out after @ms ms",
          %{"id" => inspect(handler.id), "ms" => Integer.to_string(timeout)},
          prefix: "Recovery"
        )

        :ok
    end
  end

  defp substitute_wildcard(args, hook_data) do
    Enum.map(args, fn
      :_ -> hook_data
      other -> other
    end)
  end

  defp emit_telemetry(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) do
      :telemetry.execute(
        [:process_hub, :coordinator, event],
        measurements,
        metadata
      )
    end

    :ok
  end
end
