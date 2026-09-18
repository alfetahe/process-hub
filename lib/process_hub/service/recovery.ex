defmodule ProcessHub.Service.Recovery do
  @moduledoc """
  Orphan reconcile: every round converges the cluster toward the hub's declared
  list (`ProcessHub.Service.DeclaredChildren`) — it starts
  `declared − observed running anywhere` through the normal start path with
  `check_existing: true`, and stops running children whose declared entry was
  removed. The same difference covers a whole-cluster restart and a single-node
  rejoin; stop knowledge is list absence and never expires.

  > #### Experimental {: .warning}
  >
  > The orphan reconcile (the `:auto_recovery` lifecycle) is experimental and may
  > change in future releases. Use in production at your own discretion.

  The first round opens as soon as the cluster has settled (`cluster_settle_ms`)
  and every connected peer the hub knows about has delivered its registry data;
  `reconcile_grace_ms` caps that wait so a peer that never answers cannot hold
  the hub in `:recovering`. Later rounds follow completed synchronisation rounds,
  rate-limited to one per `reconcile_interval_ms`. This module owns the
  `:auto_recovery` config, the scheduling, and the recovery lifecycle; the round
  itself lives in `ProcessHub.Service.Recovery.Round` and the coordinator stays
  the GenServer. See `guides/Persistence.md` for the model.
  """

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.LoggerService
  alias ProcessHub.Service.Recovery.Round
  alias ProcessHub.Storage.RemoteManifest
  alias ProcessHub.Coordinator.State
  alias ProcessHub.Hub

  @typedoc """
  What is asking for a round: a completed synchronisation round, first-round
  evidence (the settle window or a peer's registry data), or the grace cap.
  """
  @type trigger() :: :sync | :evidence | :grace

  @default_reconcile_grace_ms 30_000
  @default_reconcile_interval_ms 15_000
  @default_cluster_settle_ms 2_000

  # The grace caps a one-shot wait before the first round, so a small value costs
  # nothing beyond starting sooner — and a suite that boots a hub per test pays
  # it every time. The interval keeps the higher floor: it is recurring, and each
  # round diffs the declared list against the cluster.
  @reconcile_grace_ms_min 50
  @reconcile_ms_min 1_000
  @reconcile_ms_max 600_000

  # A host that forms its cluster before starting its hubs may set 0.
  @cluster_settle_ms_min 0
  @cluster_settle_ms_max 60_000

  # Keys from superseded designs. Still accepted so an existing deployment keeps
  # starting, but they no longer drive anything and are dropped in a future
  # release.
  @deprecated_keys [:marker_path, :replay_timeout_ms, :recovery_timeout_ms, :stopped_row_ttl_ms]

  @doc """
  Parses the `:auto_recovery` config field into a normalized map.

  Accepts the documented shapes:

    * `false` — disabled (the default).
    * `true` — enabled with defaults.
    * `keyword()` — `:reconcile_grace_ms`, `:reconcile_interval_ms`,
      `:cluster_settle_ms`, and `:remote_manifest` (`{module, opts}`
      implementing `ProcessHub.Storage.RemoteManifest`, default `nil`).

  The superseded keys `:marker_path`, `:replay_timeout_ms`,
  `:recovery_timeout_ms`, and `:stopped_row_ttl_ms` are **deprecated**: they are
  accepted with a WARN and ignored, and will be rejected in a future release.

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
             @reconcile_grace_ms_min,
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
         {:ok, settle} <-
           validate_int(
             Keyword.get(opts, :cluster_settle_ms, @default_cluster_settle_ms),
             @cluster_settle_ms_min,
             @cluster_settle_ms_max,
             :cluster_settle_ms_out_of_range
           ),
         {:ok, remote_manifest} <-
           validate_remote_manifest(Keyword.get(opts, :remote_manifest)) do
      {:ok,
       %{
         enabled?: true,
         reconcile_grace_ms: grace,
         reconcile_interval_ms: interval,
         cluster_settle_ms: settle,
         remote_manifest: remote_manifest
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
      cluster_settle_ms: @default_cluster_settle_ms,
      remote_manifest: nil
    }
  end

  @doc """
  Parses a settings struct's `:auto_recovery` for the hub start: an unknown shape
  falls back to the disabled config with a WARN, an out-of-range value is an error.
  """
  @spec config_or_disabled(map() | struct()) ::
          {:ok, Hub.recovery_config()} | {:error, {:invalid_auto_recovery, term()}}
  def config_or_disabled(hub_conf) do
    case parse_config(Map.get(hub_conf, :auto_recovery, false)) do
      {:error, :invalid_auto_recovery} ->
        LoggerService.warning(
          "Invalid :auto_recovery config — falling back to disabled",
          %{},
          prefix: "Recovery"
        )

        {:ok, disabled_config()}

      result ->
        result
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

  defp validate_remote_manifest(value) do
    case RemoteManifest.validate(value) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_auto_recovery, {:remote_manifest, reason}}}
    end
  end

  # --- scheduling -------------------------------------------------------------

  @doc """
  Arms the two first-round timers: the settle window, after which silence from
  the cluster counts as being alone, and `reconcile_grace_ms`, which opens the
  round whatever the evidence says.

  The grace fires whether or not any peer answered, so `:normal` is reached in
  bounded time on every boot. Disabled hubs schedule nothing.
  """
  @spec schedule_first_round(Hub.t()) :: :ok
  def schedule_first_round(%Hub{recovery_config: %{enabled?: false}}), do: :ok

  def schedule_first_round(%Hub{} = hub) do
    Process.send_after(self(), :reconcile_round, hub.recovery_config.reconcile_grace_ms)
    Process.send_after(self(), :cluster_settled, hub.recovery_config.cluster_settle_ms)
    :ok
  end

  @doc """
  Returns whether `trigger` may run a round now — the single answer for the first
  round as well as for later ones.

  Triggers are `:sync` (a completed synchronisation round, the default),
  `:evidence` (the settle window closing or a peer's registry data arriving) and
  `:grace` (`reconcile_grace_ms`). Rounds never overlap. The first round waits
  for the evidence gate — the settle window passed and every connected peer the
  hub knows about heard from — except under `:grace`, which is the cap and opens
  it regardless. Evidence only ever opens the first round; later rounds follow
  the sync tick, rate-limited to one per `reconcile_interval_ms`.
  """
  @spec round_due?(State.t(), trigger()) :: boolean()
  def round_due?(state, trigger \\ :sync)
  def round_due?(%State{hub: %Hub{recovery_config: %{enabled?: false}}}, _trigger), do: false
  def round_due?(%State{reconcile_running?: true}, _trigger), do: false
  def round_due?(%State{recovery_state: :recovering}, :grace), do: true

  def round_due?(%State{recovery_state: :recovering} = state, _trigger),
    do: first_round_open?(state)

  # Evidence opens the first round only; a later round follows the sync tick.
  def round_due?(%State{}, :evidence), do: false

  def round_due?(%State{reconcile_last_at: last, hub: hub}, _trigger) do
    last === nil or
      System.monotonic_time(:millisecond) - last >= hub.recovery_config.reconcile_interval_ms
  end

  defp first_round_open?(%State{cluster_settled?: false}), do: false

  defp first_round_open?(%State{} = state) do
    state.hub.storage.misc
    |> Cluster.nodes([:connected])
    |> Enum.all?(&MapSet.member?(state.registry_delivered_by, &1))
  end

  @doc "Spawns a round when `round_due?/2` allows `trigger` one."
  @spec trigger_round(State.t(), trigger()) :: State.t()
  def trigger_round(%State{} = state, trigger \\ :sync) do
    if round_due?(state, trigger), do: spawn_round(state), else: state
  end

  @doc """
  Records that `node` has delivered its registry data. Only the first round
  waits on this evidence, so nothing is kept once the hub is `:normal`.
  """
  @spec registry_delivered(State.t(), node()) :: State.t()
  def registry_delivered(%State{recovery_state: :recovering} = state, node) do
    %{state | registry_delivered_by: MapSet.put(state.registry_delivered_by, node)}
  end

  def registry_delivered(%State{} = state, _node), do: state

  @doc "Records that the cluster settle window has passed."
  @spec cluster_settled(State.t()) :: State.t()
  def cluster_settled(%State{} = state), do: %{state | cluster_settled?: true}

  @doc """
  Runs a round in a separate process; replies to the coordinator with
  `{:reconcile_done, result}`, which it hands to `complete_round/2` —
  `Round.run_safe/2` guarantees a reply whatever happened.
  """
  @spec spawn_round(State.t()) :: State.t()
  def spawn_round(%State{hub: hub} = state) do
    coordinator = self()
    first_round? = state.recovery_state === :recovering

    spawn(fn -> send(coordinator, {:reconcile_done, Round.run_safe(hub, first_round?)}) end)

    %{state | reconcile_running?: true}
  end

  # --- coordinator transition -------------------------------------------------

  @doc """
  Completes a round: clears what `spawn_round/1` set and stamps the rate limit.
  The first round also moves the coordinator to `:normal`, dispatches the
  transition hook, and fires the async `post_recovery_replay`.
  """
  @spec complete_round(State.t(), Round.result()) :: State.t()
  def complete_round(%State{} = state, result) do
    %{state | reconcile_running?: false, reconcile_last_at: System.monotonic_time(:millisecond)}
    |> complete_first_round(result)
  end

  defp complete_first_round(%State{recovery_state: :recovering, hub: hub} = state, result) do
    state = %{state | recovery_state: :normal}

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

    state
  end

  defp complete_first_round(state, _result), do: state

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
