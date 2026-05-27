defmodule ProcessHub.Service.Recovery do
  @moduledoc """
  State-machine logic for the coordinator boot-recovery lifecycle.

  When `:auto_recovery` is enabled the coordinator transitions through
  three states (`:recovery_pending → :recovering | :normal`) on start-up.
  Two protocols can drive that lifecycle:

    * **Marker-gated (primary)** — when `:recovery_marker.enabled?` is
      `true` (the default for `auto_recovery: true`), the resolved mode
      is computed from env > marker > config at `init/1`. Marker
      present → straight to `:normal`. Marker absent → `:recovering`
      with a cspecs-only replay, then `:normal`. While the gate is
      closed cluster events are queued and drained in FIFO order on
      gate open. The marker is rewritten on every successful boot.

    * **Peer-mode-exchange (opt-out)** — when
      `:recovery_marker.enabled?` is `false`, the legacy
      `@event_recovery_state_query` / `_announce` protocol still drives
      the lifecycle (preserved for back-compat with consumers that
      depended on the previous semantics).

  Replay only produces work with a persistent `:registry_backend` (e.g.
  `{:dets, _}`); with `:ets` the dump is empty. Replay is **cspecs-only**:
  `node_pids` and metadata are not restored — bindings are recomputed
  by the first migration tick after the cluster forms.

  This module owns the pure helpers used by the coordinator:

    - parsing/validating the `:auto_recovery` and `:recovery_marker` configs
    - resolving the recovery mode (`resolve_mode/3`) with
      `PROCESS_HUB_RECOVERY_MODE` env-var precedence (`auto | force | skip`)
    - marker IO (`marker_exists?/1`, `write_marker/1`, `delete_marker/1`)
    - replaying the persisted registry into
      `Distributor.compose_start_operation/3` (best-effort, partial-success
      tolerant)
    - emitting `[:process_hub, :recovery, _]` telemetry and dispatching the
      recovery hooks

  The coordinator stays the GenServer; this module is stateless aside
  from the data passed in.
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
  @default_recovery_timeout_ms 30_000

  @recovery_window_min 1_000
  @recovery_window_max 600_000
  @replay_timeout_min 1_000
  @replay_timeout_max 3_600_000
  @recovery_timeout_min 1_000
  @recovery_timeout_max 600_000

  @env_var "PROCESS_HUB_RECOVERY_MODE"

  @typedoc "Result of a recovery-replay run."
  @type replay_result() :: %{
          child_count: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer(),
          attempted: non_neg_integer(),
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
       replay_timeout_ms: @default_replay_timeout_ms,
       recovery_timeout_ms: @default_recovery_timeout_ms
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
           ),
         {:ok, recovery_timeout} <-
           validate_int(
             Keyword.get(opts, :recovery_timeout_ms, @default_recovery_timeout_ms),
             @recovery_timeout_min,
             @recovery_timeout_max,
             :recovery_timeout_ms_out_of_range
           ) do
      {:ok,
       %{
         enabled?: true,
         recovery_window_ms: window,
         replay_timeout_ms: replay,
         recovery_timeout_ms: recovery_timeout
       }}
    end
  end

  def parse_config(_), do: {:error, :invalid_auto_recovery}

  @doc "Returns the disabled (default) config."
  @spec disabled_config() :: Hub.recovery_config()
  def disabled_config do
    %{
      enabled?: false,
      recovery_window_ms: @default_recovery_window_ms,
      replay_timeout_ms: @default_replay_timeout_ms,
      recovery_timeout_ms: @default_recovery_timeout_ms
    }
  end

  @doc """
  Parses the `:recovery_marker` config field into a normalised map.

  Accepts:

    * `nil` / unset — defaults derived from `auto_recovery_enabled?`.
    * `keyword()` / `map()` — explicit `:enabled?` and `:path`.

  Returns the normalised marker config map. The `:path` value is left
  un-resolved (the absolute path is computed later via `resolve_marker_path/2`).
  """
  @spec parse_marker_config(term(), boolean()) ::
          %{enabled?: boolean(), path: nil | String.t()}
  def parse_marker_config(nil, auto_recovery_enabled?) do
    %{enabled?: auto_recovery_enabled?, path: nil}
  end

  def parse_marker_config(opts, auto_recovery_enabled?) when is_list(opts) do
    parse_marker_config(Map.new(opts), auto_recovery_enabled?)
  end

  def parse_marker_config(%{} = opts, auto_recovery_enabled?) do
    enabled? = Map.get(opts, :enabled?, auto_recovery_enabled?)
    path = Map.get(opts, :path, nil)
    %{enabled?: !!enabled?, path: normalise_marker_path(path)}
  end

  def parse_marker_config(_other, auto_recovery_enabled?) do
    %{enabled?: auto_recovery_enabled?, path: nil}
  end

  defp normalise_marker_path(nil), do: nil
  defp normalise_marker_path(path) when is_binary(path), do: path
  defp normalise_marker_path(path) when is_list(path), do: List.to_string(path)
  defp normalise_marker_path(_), do: nil

  @doc """
  Resolves the absolute marker path for a hub.

  If `path` is non-nil, returns it as-is. Otherwise resolves to
  `<:filename.basedir(:user_data, "process_hub")>/<hub_id>/cluster.healthy`.
  """
  @spec resolve_marker_path(atom(), nil | String.t()) :: String.t()
  def resolve_marker_path(_hub_id, path) when is_binary(path) and byte_size(path) > 0, do: path

  def resolve_marker_path(hub_id, _) do
    base =
      :filename.basedir(:user_data, ~c"process_hub")
      |> to_string()

    Path.join([base, Atom.to_string(hub_id), "cluster.healthy"])
  end

  @doc """
  Returns whether the marker file at `path` exists.

  `nil` paths and unreadable parents return `false` (selecting recovery
  mode is the safe direction).
  """
  @spec marker_exists?(nil | String.t()) :: boolean()
  def marker_exists?(nil), do: false

  def marker_exists?(path) when is_binary(path) do
    try do
      File.exists?(path)
    rescue
      _ -> false
    end
  end

  def marker_exists?(_), do: false

  @doc """
  Writes a zero-byte marker file at `path`, creating parent directories.
  Idempotent on success; returns `{:error, posix()}` on IO failure.
  """
  @spec write_marker(nil | String.t()) :: :ok | {:error, term()}
  def write_marker(nil), do: :ok

  def write_marker(path) when is_binary(path) do
    parent = Path.dirname(path)

    with :ok <- ensure_parent(parent),
         :ok <- File.touch(path) do
      :ok
    end
  end

  defp ensure_parent(parent) do
    case File.mkdir_p(parent) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Deletes the marker file at `path`. Returns `:ok` if the marker is
  absent (no-op). Returns `{:error, posix()}` on permission/IO failure.
  """
  @spec delete_marker(nil | String.t()) :: :ok | {:error, term()}
  def delete_marker(nil), do: :ok

  def delete_marker(path) when is_binary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Resolves the effective recovery mode at coordinator init.

  Precedence (highest → lowest):

    1. `env` value (`"force"` → `:recovery`, `"skip"` → `:normal`)
    2. `marker_enabled?` is `false` → `:normal`
    3. `marker_exists?` is `true` → `:normal`
    4. otherwise → `:recovery`

  Unknown env values fall back to `auto` and emit a WARN log.
  """
  @spec resolve_mode(nil | String.t(), boolean(), boolean()) :: :normal | :recovery
  def resolve_mode(env, marker_exists?, marker_enabled?)
      when is_boolean(marker_exists?) and is_boolean(marker_enabled?) do
    case classify_env(env) do
      :force -> :recovery
      :skip -> :normal
      :auto -> auto_mode(marker_exists?, marker_enabled?)
    end
  end

  defp classify_env(nil), do: :auto

  defp classify_env(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "" -> :auto
      "auto" -> :auto
      "force" -> :force
      "skip" -> :skip
      other -> warn_unknown_env(other)
    end
  end

  defp classify_env(_), do: :auto

  defp warn_unknown_env(value) do
    Logger.warning(
      "Unknown #{@env_var} value #{inspect(value)}; falling back to :auto"
    )

    :auto
  end

  defp auto_mode(_marker_exists?, false), do: :normal
  defp auto_mode(true, true), do: :normal
  defp auto_mode(false, true), do: :recovery

  @doc """
  Returns the resolved env-var atom (`:auto | :force | :skip`).

  Used to label telemetry metadata. Unknown values are reported as
  `:auto` (same fallback as `resolve_mode/3`).
  """
  @spec resolved_env_mode(nil | String.t()) :: :auto | :force | :skip
  def resolved_env_mode(env), do: classify_env(env)

  @doc """
  Reads the `PROCESS_HUB_RECOVERY_MODE` env var (or `nil` if unset).
  """
  @spec read_env() :: nil | String.t()
  def read_env do
    case System.get_env(@env_var) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  @doc "Env var name used for the recovery-mode override."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  # --- marker-driven boot orchestration --------------------------------------

  @doc """
  Injects `recovery_replay: bool` into backend opts when the marker
  gate is enabled. Honours an explicitly set value if the caller
  already provided one.
  """
  @spec maybe_inject_replay_flag(keyword(), atom(), map() | struct()) :: keyword()
  def maybe_inject_replay_flag(opts, hub_id, hub_conf) do
    cond do
      Keyword.has_key?(opts, :recovery_replay) ->
        opts

      true ->
        enabled? = Map.get(hub_conf, :auto_recovery, false) != false
        cfg = parse_marker_config(Map.get(hub_conf, :recovery_marker), enabled?)

        if cfg.enabled? do
          path = resolve_marker_path(hub_id, cfg.path)
          replay? = resolve_mode(read_env(), marker_exists?(path), true) == :recovery
          Keyword.put(opts, :recovery_replay, replay?)
        else
          opts
        end
    end
  end

  @doc """
  Builds the marker config for a hub: resolves the absolute path and
  computes the initial `recovery_state` from env + filesystem.

  Returns `{marker, initial_state, resolved_mode}`. The caller (the
  coordinator's `init/1`) stamps the marker onto `%Hub{}` and decides
  what to do next via `start/2`.
  """
  @spec init_marker(atom(), term(), boolean()) ::
          {Hub.recovery_marker(), Hub.recovery_state(), :normal | :recovery}
  def init_marker(hub_id, raw, auto_recovery_enabled?) do
    cfg = parse_marker_config(raw, auto_recovery_enabled?)
    path = if cfg.enabled?, do: resolve_marker_path(hub_id, cfg.path), else: cfg.path
    mode = resolve_mode(read_env(), marker_exists?(path), cfg.enabled?)

    initial =
      cond do
        auto_recovery_enabled? and cfg.enabled? and mode == :normal -> :normal
        auto_recovery_enabled? -> :recovery_pending
        true -> :normal
      end

    {%{cfg | path: path}, initial, mode}
  end

  @doc """
  Drives the marker-gated lifecycle from coordinator init.

    * marker disabled → no-op.
    * mode `:normal` → emit `:skipped`, write the marker.
    * mode `:recovery` → emit `:started`, schedule the timeout, and
      send `self() :start_marker_replay` so the replay runs after init
      returns.

  Returns the updated state.
  """
  @spec start(Hub.t(), :normal | :recovery) :: Hub.t()
  def start(%Hub{recovery_marker: %{enabled?: false}} = state, _), do: state

  def start(%Hub{} = state, :normal) do
    emit_recovery_telemetry(
      :skipped,
      %{system_time: System.system_time()},
      %{hub_id: state.hub_id, reason: skip_reason(state), marker_path: state.recovery_marker.path}
    )

    persist_marker(state)
    state
  end

  def start(%Hub{} = state, :recovery) do
    emit_recovery_telemetry(
      :started,
      %{cspec_count: cspec_count(state.hub_id), system_time: System.system_time()},
      %{hub_id: state.hub_id, mode: env_mode(), marker_path: state.recovery_marker.path}
    )

    timer =
      Process.send_after(self(), :recovery_timeout_elapsed, state.recovery_config.recovery_timeout_ms)

    Process.send_after(self(), :start_marker_replay, 0)
    %{state | recovery_timeout_timer: timer}
  end

  @doc "Emits `[:process_hub, :recovery, :complete]` from a replay result."
  @spec emit_replay_complete(Hub.t(), map()) :: :ok
  def emit_replay_complete(%Hub{} = state, result) do
    emit_recovery_telemetry(
      :complete,
      %{
        cspec_count: result.child_count,
        succeeded: result.succeeded,
        failed: result.failed,
        skipped: result.skipped,
        elapsed_ms: result.elapsed_ms
      },
      %{hub_id: state.hub_id, mode: env_mode()}
    )
  end

  @doc "Emits `[:process_hub, :recovery, :timeout]` for the queue-gate ceiling."
  @spec emit_replay_timeout(Hub.t()) :: :ok
  def emit_replay_timeout(%Hub{} = state) do
    emit_recovery_telemetry(
      :timeout,
      %{
        cspec_count: cspec_count(state.hub_id),
        attempted: 0,
        elapsed_ms: state.recovery_config.recovery_timeout_ms
      },
      %{hub_id: state.hub_id, mode: env_mode()}
    )
  end

  @doc "Runs the replay in a separate process; replies with `{:marker_replay_done, result}`."
  @spec spawn_replay(Hub.t()) :: Hub.t()
  def spawn_replay(%Hub{} = state) do
    state = %{state | recovery_state: :recovering}
    dispatch_state_changed_hook(state, :recovery_pending, :recovering, :marker_absent)

    coord = self()

    spawn(fn ->
      result =
        try do
          replay(state, state.recovery_config)
        rescue
          _ -> empty_result()
        end

      send(coord, {:marker_replay_done, result})
    end)

    state
  end

  @doc "Opens the recovery gate, drains queued events, broadcasts the restart signal."
  @spec open_gate(Hub.t(), atom()) :: Hub.t()
  def open_gate(%Hub{recovery_state: prior} = state, reason)
      when prior in [:recovery_pending, :recovering] do
    if state.recovery_timeout_timer, do: Process.cancel_timer(state.recovery_timeout_timer)

    state = %{state | recovery_state: :normal, recovery_timeout_timer: nil}
    dispatch_state_changed_hook(state, prior, :normal, reason)
    persist_marker(state)

    state
    |> maybe_emit_restart_signal()
    |> drain_queue()
  end

  def open_gate(state, _), do: state

  @doc "Returns `true` when cluster events must be deferred (gate closed)."
  @spec gate_closed?(Hub.t()) :: boolean()
  def gate_closed?(%Hub{recovery_marker: %{enabled?: true}, recovery_state: rs})
      when rs in [:recovery_pending, :recovering],
      do: true

  def gate_closed?(_), do: false

  @doc "Appends a deferred cluster event to the queue."
  @spec enqueue(Hub.t(), term()) :: Hub.t()
  def enqueue(%Hub{recovery_event_queue: q} = state, msg),
    do: %{state | recovery_event_queue: q ++ [msg]}

  @doc """
  Handles a tagged `{:cluster_join, {:restarted, node}}` signal: queues
  it while the gate is closed; otherwise purges bindings whose
  `node_pids` list contains the restarted peer.
  """
  @spec handle_restart_signal(Hub.t(), node(), term()) :: Hub.t()
  def handle_restart_signal(state, restarted_node, msg) do
    if gate_closed?(state) do
      enqueue(state, msg)
    else
      _ = safe_purge(state.hub_id, restarted_node)
      state
    end
  end

  @doc """
  Reports the `cspec_count` currently persisted, used for telemetry
  measurements at recovery boot.
  """
  @spec cspec_count(ProcessHub.hub_id()) :: non_neg_integer()
  def cspec_count(hub_id) do
    try do
      hub_id |> ProcessRegistry.dump_all() |> map_size()
    rescue
      _ -> 0
    end
  end

  defp empty_result do
    %{
      child_count: 0,
      succeeded: 0,
      failed: 0,
      skipped: 0,
      attempted: 0,
      elapsed_ms: 0,
      reason: :completed
    }
  end

  defp persist_marker(%Hub{recovery_marker: %{path: path}, hub_id: hub_id}) do
    case write_marker(path) do
      :ok ->
        :ok

      {:error, reason} ->
        LoggerService.error(
          "Failed to write recovery marker at @path: @reason",
          %{"path" => inspect(path), "reason" => inspect(reason)},
          prefix: "Coordinator",
          hub_id: hub_id
        )

        :ok
    end
  end

  defp skip_reason(%Hub{recovery_marker: %{path: path}}) do
    cond do
      env_mode() == :skip -> :env_skip
      marker_exists?(path) -> :marker_present
      true -> :disabled
    end
  end

  defp env_mode, do: resolved_env_mode(read_env())

  defp drain_queue(%Hub{recovery_event_queue: []} = state), do: state

  defp drain_queue(%Hub{recovery_event_queue: queue} = state) do
    Enum.each(queue, &send(self(), &1))
    %{state | recovery_event_queue: []}
  end

  defp maybe_emit_restart_signal(%Hub{recovery_restart_signal_sent?: true} = state), do: state

  defp maybe_emit_restart_signal(%Hub{recovery_marker: %{enabled?: false}} = state), do: state

  defp maybe_emit_restart_signal(%Hub{} = state) do
    Dispatcher.dispatch_event(
      state.procs.event_queue,
      @event_cluster_join,
      {:restarted, node()},
      %{members: :external}
    )

    %{state | recovery_restart_signal_sent?: true}
  end

  defp safe_purge(hub_id, restarted_node) do
    if function_exported?(ProcessRegistry, :purge_node_bindings, 2) do
      try do
        ProcessRegistry.purge_node_bindings(hub_id, restarted_node)
      rescue
        _ -> :ok
      end
    end

    :ok
  end


  @doc """
  Deletes the recovery marker on the local node so the next coordinator
  boot selects recovery mode.

  Safe to call on a running hub — only the marker file is touched.
  Idempotent (returns `:ok` even when the marker is absent). Hubs with
  `recovery_marker.enabled?: false` are no-ops.

  See `prepare_recovery_cluster/1` for the RPC fan-out variant.
  """
  @spec prepare_recovery_local(ProcessHub.hub_id()) :: :ok | {:error, term()}
  def prepare_recovery_local(hub_id) do
    with {:ok, hub} <- fetch_hub_state(hub_id) do
      if hub.recovery_marker.enabled? do
        delete_marker(hub.recovery_marker.path)
      else
        :ok
      end
    end
  end

  @doc """
  Fans out `prepare_recovery_local/1` to every member of the hub via
  `:rpc.multicall/4`.

  Returns:

    * `{:ok, [node]}` — every member acked.
    * `{:partial, [acked], [unreachable]}` — at least one peer failed.
    * `{:error, reason}` — cluster API itself failed (hub not running).
  """
  @spec prepare_recovery_cluster(ProcessHub.hub_id()) ::
          {:ok, [node()]} | {:partial, [node()], [node()]} | {:error, term()}
  def prepare_recovery_cluster(hub_id) do
    with {:ok, _hub} <- fetch_hub_state(hub_id) do
      nodes = ProcessHub.nodes(hub_id, [:include_local])

      {replies, bad_nodes} =
        :rpc.multicall(nodes, ProcessHub, :prepare_recovery, [hub_id], 5_000)

      {acked, errored} = partition_rpc_results(nodes, replies, bad_nodes)
      unreachable = bad_nodes ++ errored

      cond do
        unreachable == [] -> {:ok, acked}
        true -> {:partial, acked, unreachable}
      end
    end
  end

  defp fetch_hub_state(hub_id) do
    case Process.whereis(hub_id) do
      nil ->
        {:error, :not_alive}

      _pid ->
        try do
          {:ok, GenServer.call(hub_id, :get_state)}
        catch
          :exit, reason -> {:error, reason}
        end
    end
  end

  defp partition_rpc_results(nodes, replies, bad_nodes) do
    reachable = nodes -- bad_nodes

    Enum.zip(reachable, replies)
    |> Enum.reduce({[], []}, fn
      {node, :ok}, {acked, errored} -> {[node | acked], errored}
      {node, _other}, {acked, errored} -> {acked, [node | errored]}
    end)
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

    {succeeded, failed, skipped, reason} =
      case child_count do
        0 ->
          {0, 0, 0, :empty}

        _ ->
          execute_replay(state, dump, replay_timeout_ms, started_at)
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    attempted = succeeded + failed + skipped

    emit_telemetry(
      :recovery_replay_completed,
      %{
        child_count: child_count,
        succeeded: succeeded,
        failed: failed,
        skipped: skipped,
        elapsed_ms: elapsed_ms
      },
      %{hub_id: state.hub_id, reason: reason}
    )

    HookManager.dispatch_hook(state.storage.hook, Hook.post_recovery_replay(), %{
      hub_id: state.hub_id,
      child_count: child_count,
      succeeded: succeeded,
      failed: failed,
      skipped: skipped,
      reason: reason
    })

    %{
      child_count: child_count,
      succeeded: succeeded,
      failed: failed,
      skipped: skipped,
      attempted: attempted,
      elapsed_ms: elapsed_ms,
      reason: reason
    }
  end

  defp execute_replay(state, dump, replay_timeout_ms, started_at) do
    # Project every persisted row to its cspec only. Recovery does not
    # restore node_pids or metadata — bindings are recomputed by the
    # migration tick after the cluster forms (see design.md §D7).
    {child_specs, skipped} = project_cspecs(dump)

    case child_specs do
      [] ->
        {0, 0, skipped, :completed}

      _ ->
        run_replay_task(state, child_specs, skipped, replay_timeout_ms, started_at)
    end
  end

  defp project_cspecs(dump) do
    Enum.reduce(dump, {[], 0}, fn {child_id, value}, {specs, skipped} ->
      case extract_cspec(value) do
        {:ok, cspec} ->
          {[cspec | specs], skipped}

        :skip ->
          LoggerService.warning(
            "Recovery replay: skipping invalid persisted row for @cid",
            %{"cid" => inspect(child_id)},
            prefix: "Recovery"
          )

          {specs, skipped + 1}
      end
    end)
  end

  defp extract_cspec(%{} = cspec), do: {:ok, cspec}
  defp extract_cspec({cspec, _node_pids}) when is_map(cspec), do: {:ok, cspec}
  defp extract_cspec({cspec, _node_pids, _metadata}) when is_map(cspec), do: {:ok, cspec}
  defp extract_cspec(_), do: :skip

  defp run_replay_task(state, child_specs, skipped, replay_timeout_ms, started_at) do
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
    n = length(child_specs)

    receive do
      {^ref, {:ok, _operation}} ->
        Process.demonitor(mon_ref, [:flush])
        {n, 0, skipped, :completed}

      {^ref, {:error, reason}} ->
        Process.demonitor(mon_ref, [:flush])

        LoggerService.warning(
          "Recovery replay returned error: @reason",
          %{"reason" => inspect(reason)},
          prefix: "Recovery"
        )

        {0, n, skipped, :completed}

      {:DOWN, ^mon_ref, :process, ^pid, reason} ->
        LoggerService.warning(
          "Recovery replay task crashed: @reason",
          %{"reason" => inspect(reason)},
          prefix: "Recovery"
        )

        {0, n, skipped, :completed}
    after
      remaining ->
        Process.demonitor(mon_ref, [:flush])

        LoggerService.warning(
          "Recovery replay timed out after @ms ms; continuing in background",
          %{"ms" => Integer.to_string(replay_timeout_ms)},
          prefix: "Recovery"
        )

        {0, n, skipped, :replay_timeout}
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

  @doc """
  Emits a `[:process_hub, :recovery, event]` telemetry event.

  Used for the recovery-lifecycle observability events
  (`:started | :complete | :skipped | :timeout`). Distinct from the
  legacy `[:process_hub, :coordinator, _]` replay events.
  """
  @spec emit_recovery_telemetry(atom(), map(), map()) :: :ok
  def emit_recovery_telemetry(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) do
      :telemetry.execute(
        [:process_hub, :recovery, event],
        measurements,
        metadata
      )
    end

    :ok
  end
end
