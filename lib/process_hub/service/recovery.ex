defmodule ProcessHub.Service.Recovery do
  @moduledoc """
  Orphan reconcile: the continuously computed difference that replaces boot-time
  replay.

  > #### Experimental {: .warning}
  >
  > The orphan reconcile (the `:auto_recovery` lifecycle) is experimental and may
  > change in future releases.
  > Use in production at your own discretion.

  A node cannot answer "does the cluster already hold my children?" from its own
  disk — the disk records how *this* node died, not what the cluster currently
  holds. So nothing asks it. Instead, every round computes

      orphans = durable candidates − children observed running anywhere − stopped rows

  and submits the remainder through the normal
  `ProcessHub.Service.Distributor.compose_start_operation/3` with
  `check_existing: true`. Because it is a difference rather than a mode, the same
  code covers both directions: after a whole-cluster power loss the live registry
  is empty and everything returns; after a single-node rejoin the peers already
  hold the children and the difference is empty.

  The first round runs `reconcile_grace_ms` after coordinator start — with or
  without peers, so `:normal` is always reached in bounded time — and thereafter
  on synchronisation-round completion, rate-limited to one per
  `reconcile_interval_ms`.

  This module owns:

    - parsing/validating the `:auto_recovery` config
    - running a round (`reconcile/2`) and its scheduling helpers
    - duplicate-binding resolution
    - dispatching the recovery hooks

  The coordinator stays the GenServer; this module is stateless aside from the
  data passed in and the per-hub orphan-pending map it keeps in misc storage.
  """

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.LoggerService
  alias ProcessHub.Service.Migration
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.ProcessRegistry.Row
  alias ProcessHub.Service.Storage
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Hub

  @default_reconcile_grace_ms 30_000
  @default_reconcile_interval_ms 15_000
  @default_stopped_row_ttl_ms 86_400_000

  @reconcile_ms_min 1_000
  @reconcile_ms_max 600_000
  @stopped_row_ttl_min 60_000
  @stopped_row_ttl_max 31_536_000_000

  # Keys from the marker-gated design. Still accepted so an existing deployment
  # keeps starting, but they no longer drive anything and are dropped in a future
  # release.
  @deprecated_keys [:marker_path, :replay_timeout_ms, :recovery_timeout_ms]

  @typedoc "Result of one orphan reconcile round."
  @type round_result() :: %{
          candidates: non_neg_integer(),
          orphans: non_neg_integer(),
          started: non_neg_integer(),
          skipped_pending: non_neg_integer(),
          duplicates: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          reason: :completed | :read_error | :draining | :crashed
        }

  @doc """
  Parses the `:auto_recovery` config field into a normalized map.

  Accepts the documented shapes:

    * `false` — disabled (the default).
    * `true` — enabled with defaults.
    * `keyword()` — `:reconcile_grace_ms`, `:reconcile_interval_ms`, and
      `:stopped_row_ttl_ms`.

  The marker-era keys `:marker_path`, `:replay_timeout_ms`, and
  `:recovery_timeout_ms` are **deprecated**: they are accepted with a WARN and
  ignored, and will be rejected in a future release.

  Returns `{:ok, recovery_config}`, or `{:error, {:invalid_auto_recovery, reason}}`
  for out-of-range values. Unknown shapes return `{:error, :invalid_auto_recovery}`
  so the caller can decide whether to fall back to disabled or to refuse to start.
  """
  @spec parse_config(false | true | keyword() | term()) ::
          {:ok, Hub.recovery_config()}
          | {:error, :invalid_auto_recovery | {:invalid_auto_recovery, atom()}}
  def parse_config(false), do: {:ok, disabled_config()}

  def parse_config(true), do: {:ok, %{disabled_config() | enabled?: true}}

  def parse_config(opts) when is_list(opts) do
    warn_deprecated_keys(opts)

    with {:ok, grace} <-
           validate_int(
             Keyword.get(opts, :reconcile_grace_ms, @default_reconcile_grace_ms),
             @reconcile_ms_min,
             @reconcile_ms_max,
             :reconcile_grace_ms_out_of_range
           ),
         {:ok, interval} <-
           validate_int(
             Keyword.get(opts, :reconcile_interval_ms, @default_reconcile_interval_ms),
             @reconcile_ms_min,
             @reconcile_ms_max,
             :reconcile_interval_ms_out_of_range
           ),
         {:ok, stopped_row_ttl} <-
           validate_int(
             Keyword.get(opts, :stopped_row_ttl_ms, @default_stopped_row_ttl_ms),
             @stopped_row_ttl_min,
             @stopped_row_ttl_max,
             :stopped_row_ttl_ms_out_of_range
           ) do
      {:ok,
       %{
         enabled?: true,
         reconcile_grace_ms: grace,
         reconcile_interval_ms: interval,
         stopped_row_ttl_ms: stopped_row_ttl
       }}
    end
  end

  def parse_config(_), do: {:error, :invalid_auto_recovery}

  @doc "Returns the disabled (default) config."
  @spec disabled_config() :: Hub.recovery_config()
  def disabled_config do
    %{
      enabled?: false,
      reconcile_grace_ms: @default_reconcile_grace_ms,
      reconcile_interval_ms: @default_reconcile_interval_ms,
      stopped_row_ttl_ms: @default_stopped_row_ttl_ms
    }
  end

  @doc """
  Returns the parsed `:auto_recovery` config for a settings struct, falling back to
  the disabled config for any shape the coordinator would reject.
  """
  @spec config_or_disabled(map() | struct()) :: Hub.recovery_config()
  def config_or_disabled(hub_conf) do
    case parse_config(Map.get(hub_conf, :auto_recovery, false)) do
      {:ok, config} -> config
      {:error, _} -> disabled_config()
    end
  end

  defp warn_deprecated_keys(opts) do
    Enum.each(@deprecated_keys, fn key ->
      if Keyword.has_key?(opts, key) do
        LoggerService.warning(
          ":auto_recovery key @key is deprecated and ignored; it will be rejected in a " <>
            "future release. See migration-guide.md",
          %{"key" => inspect(key)},
          prefix: "Recovery"
        )
      end
    end)
  end

  defp validate_int(value, min, max, _err)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp validate_int(_value, _min, _max, err), do: {:error, {:invalid_auto_recovery, err}}

  # --- scheduling -------------------------------------------------------------

  @doc """
  Schedules the first reconcile round `reconcile_grace_ms` after coordinator start.

  The timer fires whether or not any peer joined, so `:normal` is reached in
  bounded time on every boot. Disabled hubs schedule nothing.
  """
  @spec schedule_first_round(Hub.t()) :: Hub.t()
  def schedule_first_round(%Hub{recovery_config: %{enabled?: false}} = hub), do: hub

  def schedule_first_round(%Hub{} = hub) do
    Process.send_after(self(), :reconcile_round, hub.recovery_config.reconcile_grace_ms)
    hub
  end

  @doc """
  Returns whether a round triggered by a completed synchronisation round may run.

  Rounds are rate-limited to one per `reconcile_interval_ms`, are never started
  before the first (grace-scheduled) round, and never overlap.
  """
  @spec round_due?(Hub.t()) :: boolean()
  def round_due?(%Hub{recovery_config: %{enabled?: false}}), do: false
  def round_due?(%Hub{reconcile_running?: true}), do: false
  def round_due?(%Hub{recovery_state: :recovering}), do: false

  def round_due?(%Hub{reconcile_last_at: last, recovery_config: config}) do
    last === nil or
      System.monotonic_time(:millisecond) - last >= config.reconcile_interval_ms
  end

  @doc """
  Runs a round in a separate process; replies to the coordinator with
  `{:reconcile_done, result}`.
  """
  @spec spawn_round(Hub.t()) :: Hub.t()
  def spawn_round(%Hub{} = hub) do
    coordinator = self()
    first_round? = hub.recovery_state === :recovering

    spawn(fn ->
      # The reply is what clears `reconcile_running?` and, on the first round,
      # reaches `:normal` — so every exit path must still send one. A registry or
      # peer call that times out exits rather than raising, hence the catch.
      result =
        try do
          reconcile(hub, first_round?)
        rescue
          error -> crashed_result(error)
        catch
          kind, reason -> crashed_result({kind, reason})
        end

      send(coordinator, {:reconcile_done, result})
    end)

    %{hub | reconcile_running?: true}
  end

  # --- the round --------------------------------------------------------------

  # One round: read the durable candidates, subtract what is accounted for, start
  # the rest, resolve duplicates, report. A read error yields no starts and no
  # duplicate resolution — a transient failure must never be mistaken for
  # "everything was deliberately removed".
  defp reconcile(%Hub{} = hub, first_round?) do
    started_at = System.monotonic_time(:millisecond)

    # A draining node must start nothing, and no other node's ring owner can be
    # draining: draining removes the node from every peer's membership before
    # children move, so it never owns a candidate.
    result =
      if Migration.draining?(hub),
        do: empty_result(:draining),
        else: run_round(hub, first_round?)

    result = %{result | elapsed_ms: System.monotonic_time(:millisecond) - started_at}

    HookManager.dispatch_hook(hub.storage.hook, Hook.reconcile_round(), %{
      hub_id: hub.hub_id,
      first_round: first_round?,
      measurements: Map.delete(result, :reason)
    })

    result
  end

  defp run_round(hub, first_round?) do
    case Storage.read_durable(hub.hub_id) do
      {:error, reason} ->
        LoggerService.warning(
          "Reconcile skipped: durable registry unreadable (@reason)",
          %{"reason" => inspect(reason)},
          prefix: "Recovery"
        )

        empty_result(:read_error)

      {:ok, rows} ->
        candidates = candidate_rows(rows)
        live = ProcessRegistry.dump(hub.hub_id)
        registered = ProcessRegistry.dump_all(hub.hub_id)

        {orphans, skipped_pending} = orphan_set(hub, candidates, live, registered)
        started = start_orphans(hub, orphans, map_size(candidates), first_round?)
        duplicates = resolve_duplicates(hub, live)

        %{
          empty_result(:completed)
          | candidates: map_size(candidates),
            orphans: length(orphans),
            started: started,
            skipped_pending: skipped_pending,
            duplicates: duplicates
        }
    end
  end

  # `read_durable/1` returns raw storage rows; keep the well-formed registry ones.
  defp candidate_rows(rows) do
    Enum.reduce(rows, %{}, fn
      {child_id, {%{} = child_spec, node_pids, metadata}}, acc
      when is_list(node_pids) and is_map(metadata) ->
        Map.put(acc, child_id, {child_spec, metadata})

      _row, acc ->
        acc
    end)
  end

  # orphans = candidates − observed running anywhere − stopped − not-yet-confirmed.
  #
  # The two-consecutive-rounds rule applies only to children the live registry
  # still knows about: those are the ones a migration can leave momentarily
  # unbound. A candidate with no live row at all — the whole-cluster restart case —
  # has nothing in flight to wait for and is restored on the first round.
  defp orphan_set(hub, candidates, live, registered) do
    unaccounted =
      Enum.reject(candidates, fn {child_id, {_child_spec, metadata}} ->
        Map.has_key?(live, child_id) or stopped?(child_id, metadata, registered)
      end)

    pending = Storage.get(hub.storage.misc, StorageKey.rop()) || MapSet.new()

    {confirmed, deferred} =
      Enum.split_with(unaccounted, fn {child_id, _row} ->
        not Map.has_key?(registered, child_id) or MapSet.member?(pending, child_id)
      end)

    Storage.insert(
      hub.storage.misc,
      StorageKey.rop(),
      MapSet.new(unaccounted, fn {child_id, _row} -> child_id end)
    )

    {Enum.map(confirmed, fn {_child_id, {child_spec, _metadata}} -> child_spec end),
     length(deferred)}
  end

  # A stopped row is excluded on every node, including one whose durable copy
  # still shows the child running at a lower epoch.
  defp stopped?(child_id, durable_metadata, registered) do
    live_metadata =
      case Map.get(registered, child_id) do
        {_child_spec, _node_pids, metadata} -> metadata
        _ -> nil
      end

    if Row.wins_merge?(live_metadata, durable_metadata) do
      Row.stopped?(live_metadata)
    else
      Row.stopped?(durable_metadata)
    end
  end

  defp start_orphans(_hub, [], _candidate_count, _first_round?), do: 0

  defp start_orphans(hub, child_specs, candidate_count, first_round?) do
    if first_round? do
      HookManager.dispatch_hook_blocking(
        hub.storage.hook,
        Hook.pre_recovery_replay(),
        %{hub_id: hub.hub_id, child_count: candidate_count},
        hub.recovery_config.reconcile_interval_ms
      )
    end

    submit_orphans(hub, child_specs, true)
  end

  # `check_existing: true` rejects the whole batch when any child raced into the
  # registry between the difference and the submit; drop the racers and retry once.
  defp submit_orphans(_hub, [], _retry?), do: 0

  defp submit_orphans(hub, child_specs, retry?) do
    opts =
      [
        {:auto_recovery_replay, true},
        {:awaitable, false},
        {:check_existing, true},
        {:disable_logging, true},
        {:init_cids, Enum.map(child_specs, & &1.id)}
      ]
      |> Distributor.default_init_opts()

    case Distributor.compose_start_operation(hub, child_specs, opts) do
      {:ok, _operation} ->
        length(child_specs)

      {:error, {:already_started, child_ids}} when retry? ->
        submit_orphans(hub, Enum.reject(child_specs, &(&1.id in child_ids)), false)

      {:error, reason} ->
        LoggerService.warning(
          "Reconcile could not start @count orphans: @reason",
          %{"count" => Integer.to_string(length(child_specs)), "reason" => inspect(reason)},
          prefix: "Recovery"
        )

        0
    end
  end

  # --- duplicate bindings -----------------------------------------------------

  # Each node resolves only its own instance: the decision is a pure function of
  # the (converged) registry and the ring, so every node reaches the same verdict
  # and exactly the non-keepers act.
  defp resolve_duplicates(hub, live) do
    case Enum.filter(live, fn {_child_id, {_cs, node_pids, _m}} -> length(node_pids) > 1 end) do
      [] -> 0
      multi_bound -> stop_local_duplicates(hub, multi_bound, keeper_map(hub, multi_bound))
    end
  end

  defp stop_local_duplicates(hub, multi_bound, keepers) do
    Enum.reduce(multi_bound, 0, fn {child_id, {_child_spec, node_pids, _metadata}}, acc ->
      observed = Keyword.keys(node_pids)
      kept = Map.fetch!(keepers, child_id)
      stopped_nodes = observed -- kept

      cond do
        stopped_nodes === [] -> acc
        node() not in stopped_nodes -> acc + 1
        true -> stop_duplicate(hub, child_id, observed, kept, stopped_nodes) + acc
      end
    end)
  end

  defp keeper_map(hub, multi_bound) do
    dist_strategy = Storage.get(hub.storage.misc, StorageKey.strdist())
    redun_strategy = Storage.get(hub.storage.misc, StorageKey.strred())
    replication = RedundancyStrategy.replication_factor(redun_strategy)
    child_ids = Enum.map(multi_bound, fn {child_id, _row} -> child_id end)
    assigned = DistributionStrategy.belongs_to(dist_strategy, hub, child_ids, replication)

    Map.new(multi_bound, fn {child_id, {_child_spec, node_pids, _metadata}} ->
      observed = Keyword.keys(node_pids)

      case Enum.filter(observed, &(&1 in Map.get(assigned, child_id, []))) do
        [] -> {child_id, [Enum.min(observed)]}
        owners -> {child_id, owners}
      end
    end)
  end

  defp stop_duplicate(hub, child_id, observed, kept, stopped_nodes) do
    LoggerService.warning(
      "Reconcile: @cid bound on @observed; keeping @kept, stopping local instance",
      %{
        "cid" => inspect(child_id),
        "observed" => inspect(observed),
        "kept" => inspect(kept)
      },
      prefix: "Recovery"
    )

    Distributor.children_terminate(hub, [child_id])

    HookManager.dispatch_hook(hub.storage.hook, Hook.reconcile_duplicate(), %{
      hub_id: hub.hub_id,
      child_id: child_id,
      instance_count: length(observed),
      kept_node: List.first(kept),
      stopped_nodes: stopped_nodes
    })

    1
  end

  defp crashed_result(error) do
    LoggerService.warning(
      "Reconcile round crashed: @error",
      %{"error" => inspect(error)},
      prefix: "Recovery"
    )

    empty_result(:crashed)
  end

  defp empty_result(reason) do
    %{
      candidates: 0,
      orphans: 0,
      started: 0,
      skipped_pending: 0,
      duplicates: 0,
      elapsed_ms: 0,
      reason: reason
    }
  end

  # --- coordinator transition -------------------------------------------------

  @doc """
  Completes the first round: moves the coordinator to `:normal`, dispatches the
  transition hook, and fires the async `post_recovery_replay`.
  """
  @spec complete_first_round(Hub.t(), round_result()) :: Hub.t()
  def complete_first_round(%Hub{recovery_state: :recovering} = hub, result) do
    hub = %{hub | recovery_state: :normal}

    HookManager.dispatch_hook(hub.storage.hook, Hook.recovery_state_changed(), %{
      hub_id: hub.hub_id,
      from: :recovering,
      to: :normal,
      reason: :reconcile_complete,
      measurements: Map.take(result, [:candidates, :orphans, :started, :duplicates, :elapsed_ms])
    })

    HookManager.dispatch_hook(hub.storage.hook, Hook.post_recovery_replay(), %{
      hub_id: hub.hub_id,
      child_count: result.candidates,
      succeeded: result.started,
      failed: 0,
      reason: result.reason
    })

    hub
  end

  def complete_first_round(hub, _result), do: hub

  @doc """
  Returns the coordinator's current `:recovery_state`.

  Returns `:normal` when the hub does not exist or was started without
  `:auto_recovery`.
  """
  @spec recovery_state(ProcessHub.hub_id()) :: :recovering | :normal
  def recovery_state(hub_id) do
    case Process.whereis(hub_id) do
      nil ->
        :normal

      _pid ->
        try do
          GenServer.call(hub_id, :get_recovery_state)
        catch
          :exit, _ -> :normal
        end
    end
  end

  @doc """
  Blocks until the coordinator reaches `:normal` or `timeout_ms` elapses.

  Returns `:ok` on reaching `:normal` (immediately when the hub does not exist
  or has no recovery), or `{:error, :timeout}` otherwise. `:normal` means the
  first reconcile round has completed, so callers SHOULD size the timeout above
  `reconcile_grace_ms`.
  """
  @spec await_normal(ProcessHub.hub_id(), non_neg_integer()) :: :ok | {:error, :timeout}
  def await_normal(hub_id, timeout_ms \\ 60_000) do
    case Process.whereis(hub_id) do
      nil ->
        :ok

      _pid ->
        try do
          GenServer.call(hub_id, {:await_normal, timeout_ms}, timeout_ms + 1_000)
        catch
          :exit, _ -> {:error, :timeout}
        end
    end
  end

  @doc """
  Deprecated. Armed the next boot for marker-driven replay by deleting the local
  marker file.

  There is no marker any more: every node reconciles its durable registry against
  the cluster continuously, so recovery after an outage needs no pre-boot step.
  The function is kept so existing operator tooling keeps running — it logs a
  warning and returns `:ok` without touching the filesystem.

  Scheduled for removal in a future release.
  """
  @deprecated "The recovery marker is no longer used; this is a no-op. See migration-guide.md"
  @spec prepare_recovery(ProcessHub.hub_id()) :: :ok
  def prepare_recovery(hub_id) do
    warn_marker_api("prepare_recovery/1", hub_id)
    :ok
  end

  @doc """
  Deprecated. Fanned `prepare_recovery/1` out to every hub member.

  A no-op for the same reason as `prepare_recovery/1`; it still reports the hub's
  members so existing callers keep matching on `{:ok, nodes}`. Returns
  `{:error, :not_alive}` when the hub is not running, as before.

  Scheduled for removal in a future release.
  """
  @deprecated "The recovery marker is no longer used; this is a no-op. See migration-guide.md"
  @spec prepare_recovery_cluster(ProcessHub.hub_id()) :: {:ok, [node()]} | {:error, :not_alive}
  def prepare_recovery_cluster(hub_id) do
    warn_marker_api("prepare_recovery_cluster/1", hub_id)

    case Process.whereis(hub_id) do
      nil -> {:error, :not_alive}
      _pid -> {:ok, ProcessHub.nodes(hub_id, [:include_local])}
    end
  end

  defp warn_marker_api(function, hub_id) do
    LoggerService.warning(
      "@function is deprecated and does nothing: there is no recovery marker to " <>
        "arm. It will be removed in a future release. See migration-guide.md",
      %{"function" => function},
      prefix: "Recovery",
      hub_id: hub_id
    )
  end
end
