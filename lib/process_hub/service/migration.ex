defmodule ProcessHub.Service.Migration do
  @moduledoc """
  Deferred-migration list and graceful node drain for the migration consent
  protocol. See `ProcessHub.Strategy.Migration.MigrationConsent`.
  """

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Coordinator
  alias ProcessHub.Hub
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.LoggerService
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.State
  alias ProcessHub.Service.Storage
  alias ProcessHub.Strategy.Migration.MigrationConsent
  alias ProcessHub.Strategy.Migration.SwapMigration
  alias ProcessHub.Task.ClusterUpdateTask.NodeUp

  @drain_timeout 60_000

  @type entry() :: %{child_id: ProcessHub.child_id(), deferred_at: integer(), ready: boolean()}

  @spec deferred_list(Hub.t()) :: [entry()]
  def deferred_list(hub), do: Storage.get(hub.storage.misc, StorageKey.mdl()) || []

  @spec deferred_child_ids(Hub.t()) :: MapSet.t()
  def deferred_child_ids(hub), do: MapSet.new(deferred_list(hub), & &1.child_id)

  @spec retry_interval(Hub.t()) :: pos_integer()
  def retry_interval(hub), do: settings(hub).retry_interval

  @doc "Parks children in the deferred list and ensures the retry tick runs."
  @spec defer_children(Hub.t(), [ProcessHub.child_id()]) :: :ok
  def defer_children(_hub, []), do: :ok

  def defer_children(hub, child_ids) do
    now = System.monotonic_time(:millisecond)

    added =
      update_deferred(hub, fn entries ->
        known = MapSet.new(entries, & &1.child_id)

        added =
          child_ids
          |> Enum.uniq()
          |> Enum.reject(&MapSet.member?(known, &1))
          |> Enum.map(&%{child_id: &1, deferred_at: now, ready: false})

        {entries ++ added, added}
      end)

    if added !== [] do
      ids = Enum.map(added, & &1.child_id)
      HookManager.dispatch_hook(hub.storage.hook, Hook.migration_deferred(), %{child_ids: ids})
      ensure_tick(hub, retry_interval(hub))
    end

    :ok
  end

  @doc "Marks a deferred child ready; it migrates on the next retry tick."
  @spec migration_ready(ProcessHub.hub_id() | Hub.t(), ProcessHub.child_id()) ::
          :ok | {:error, :not_deferred}
  def migration_ready(hub_id, child_id) when is_atom(hub_id) do
    migration_ready(Coordinator.get_hub(hub_id), child_id)
  end

  def migration_ready(hub, child_id) do
    update_deferred(hub, fn entries ->
      if Enum.any?(entries, &(&1.child_id === child_id)) do
        {Enum.map(entries, &if(&1.child_id === child_id, do: %{&1 | ready: true}, else: &1)), :ok}
      else
        {entries, {:error, :not_deferred}}
      end
    end)
    |> case do
      :ok -> ensure_tick(hub, 0)
      error -> error
    end
  end

  @doc """
  One retry pass: prunes entries whose child died or is assigned back to the
  local node, migrates the ready, re-consenting and expired ones, and returns
  the number of entries left.
  """
  @spec handle_retry_tick(Hub.t()) :: non_neg_integer()
  def handle_retry_tick(hub), do: run_pass(hub, :consent).remaining

  @doc """
  Migrates one child to `target_node`, handing its state over per the hub's
  migration strategy — the same per-child move a drain performs, invocable for
  a single child with an explicit target. The child's declared-list entry is
  untouched by the move, so a crash mid-migration heals through the reconcile
  instead of losing the child.

  Runs on the node currently hosting the child and routes itself there when
  called elsewhere. The consent protocol is NOT queried — the caller decides
  the child may move; a drain remains the consent-gated path.

  The distribution strategy still considers the child assigned by its own
  arithmetic, so a later topology event may migrate it back — callers healing
  toward an off-assignment placement must be prepared to re-apply.
  """
  @spec migrate_child(ProcessHub.hub_id(), ProcessHub.child_id(), node()) ::
          :ok | {:error, :not_found | :not_a_member | :same_node | term()}
  def migrate_child(hub_id, child_id, target_node) when is_atom(hub_id) do
    hub = Coordinator.get_hub(hub_id)
    hub_nodes = Cluster.nodes(hub.storage.misc, [:include_local])

    with :ok <- member_check(hub_nodes, target_node),
         {:ok, cspec, meta, hosting_node} <- child_row(hub, child_id),
         :ok <- if(hosting_node === target_node, do: {:error, :same_node}, else: :ok) do
      if hosting_node in [nil, node()] do
        strategy = Storage.get(hub.storage.misc, StorageKey.strmigr())
        stop_local = if hosting_node === node(), do: [child_id], else: []
        SwapMigration.migrate(hub, strategy, [{cspec, meta, [target_node]}], stop_local)
      else
        try do
          :erpc.call(hosting_node, __MODULE__, :migrate_child, [hub_id, child_id, target_node])
        catch
          _, reason -> {:error, {:migrate_route_failed, hosting_node, reason}}
        end
      end
    end
  end

  defp member_check(hub_nodes, target_node) do
    if target_node in hub_nodes, do: :ok, else: {:error, :not_a_member}
  end

  defp child_row(hub, child_id) do
    case ProcessRegistry.lookup(hub.hub_id, child_id, with_metadata: true) do
      {cspec, node_pids, meta} ->
        hosting =
          case node_pids do
            [{n, _pid} | _] -> n
            _ -> nil
          end

        {:ok, cspec, meta, hosting}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Drains the local node before shutdown: removes it from the distribution
  cluster-wide, migrates every local child away through the consent gate, and
  force-migrates whatever is still deferred at the `:timeout` deadline
  (default #{@drain_timeout} ms). Leaves children untouched on error.
  """
  @spec drain(ProcessHub.hub_id() | Hub.t(), keyword()) ::
          {:ok, %{migrated: non_neg_integer(), forced: non_neg_integer()}}
          | {:error, :no_target_nodes | :draining | :partitioned | :locked}
  def drain(hub_or_id, opts \\ [])

  def drain(hub_id, opts) when is_atom(hub_id), do: drain(Coordinator.get_hub(hub_id), opts)

  def drain(hub, opts) do
    with :ok <- preconditions(hub) do
      do_drain(hub, Keyword.get(opts, :timeout, @drain_timeout))
    end
  end

  @spec draining?(Hub.t()) :: boolean()
  def draining?(hub), do: Storage.get(hub.storage.misc, StorageKey.drn()) !== nil

  @doc false
  # Runs on every cluster node: drops the draining node from the membership and
  # the distribution, so no child is assigned to it any more.
  def handle_drain_distribution_removal(hub, draining_node) do
    Cluster.rem_hub_node(hub.storage.misc, draining_node)
    HookManager.dispatch_hook(hub.storage.hook, Hook.pre_node_leave(), %{node: draining_node})
    :ok
  end

  @doc false
  # Serialized on the coordinator by `update_deferred/2`.
  def apply_deferred_update(hub, fun) do
    {entries, reply} = fun.(deferred_list(hub))
    store(hub, entries)
    reply
  end

  defp run_pass(hub, mode) do
    entries = deferred_list(hub)
    {movable, pruned} = split_movable(hub, entries)
    selected = if mode === :force, do: warn_forced(movable), else: select(movable, settings(hub))
    migrated_ids = Enum.map(selected, & &1.child_id)

    SwapMigration.migrate(
      hub,
      Storage.get(hub.storage.misc, StorageKey.strmigr()),
      Enum.map(selected, fn %{cspec: cs, meta: m, target: t} -> {cs, m, [t]} end),
      selected |> Enum.filter(& &1.stop_local?) |> Enum.map(& &1.child_id)
    )

    done = MapSet.new(pruned ++ migrated_ids)

    # Drop only what this pass handled; children deferred meanwhile must survive.
    remaining =
      update_deferred(hub, fn current ->
        left = Enum.reject(current, &MapSet.member?(done, &1.child_id))
        {left, left}
      end)

    # The forced pass already runs inside the drain caller; only a retry tick
    # has to wake it.
    if remaining === [] and mode === :consent, do: notify_drain_waiter(hub)

    %{remaining: length(remaining), migrated: length(selected)}
  end

  defp select(movable, settings) do
    now = System.monotonic_time(:millisecond)

    {expired, rest} =
      Enum.split_with(movable, &(now - &1.deferred_at >= settings.max_defer_time))

    {ready, undecided} = Enum.split_with(rest, & &1.ready)

    consented =
      undecided
      |> Enum.map(&{&1.child_id, &1.pid})
      |> SwapMigration.query_consent(settings.consent_timeout)

    warn_forced(expired) ++
      ready ++ Enum.filter(undecided, &MapSet.member?(consented, &1.child_id))
  end

  defp warn_forced([]), do: []

  defp warn_forced(movable) do
    LoggerService.warning(
      "Force-migrating deferred children @child_ids",
      %{"child_ids" => Enum.map(movable, & &1.child_id)},
      prefix: "Migration"
    )

    movable
  end

  # Movable: the child still has a local pid and a freshly computed PRIMARY that
  # is not the local node. Everything else is pruned from the list. `stop_local?`
  # mirrors `compute_processable/2`: terminate locally only when the local node
  # is no longer any target (a replica target keeps its instance).
  defp split_movable(hub, entries) do
    local = node()
    targets = SwapMigration.belongs_to(hub, Enum.map(entries, & &1.child_id))

    Enum.reduce(entries, {[], []}, fn entry, {movable, pruned} ->
      nodes = Map.get(targets, entry.child_id, [])

      with {cspec, node_pids, meta} <-
             ProcessRegistry.lookup(hub.hub_id, entry.child_id, with_metadata: true),
           pid when is_pid(pid) <- Keyword.get(node_pids, local),
           [primary | _] when primary !== local <- nodes do
        extra = %{
          cspec: cspec,
          meta: meta,
          pid: pid,
          target: primary,
          stop_local?: not Enum.member?(nodes, local)
        }

        {[Map.merge(entry, extra) | movable], pruned}
      else
        _ -> {movable, [entry.child_id | pruned]}
      end
    end)
  end

  defp settings(hub) do
    strategy = Storage.get(hub.storage.misc, StorageKey.strmigr()) || %{}
    Map.get(strategy, :consent_settings) || %MigrationConsent{}
  end

  defp store(hub, []), do: Storage.remove(hub.storage.misc, StorageKey.mdl())
  defp store(hub, entries), do: Storage.insert(hub.storage.misc, StorageKey.mdl(), entries)

  # Deferred-list writes are read-modify-write from three processes — the
  # expansion worker, the retry-tick task and the readiness caller — so the
  # coordinator serializes them.
  defp update_deferred(hub, fun) do
    GenServer.call(hub.hub_id, {:migration_deferred_update, fun})
  end

  # The coordinator owns the retry timer.
  defp ensure_tick(hub, delay) do
    send(hub.hub_id, {:migration_retry_ensure, delay})
    :ok
  end

  defp preconditions(hub) do
    cond do
      Cluster.nodes(hub.storage.misc) === [] -> {:error, :no_target_nodes}
      draining?(hub) -> {:error, :draining}
      State.is_partitioned?(hub) -> {:error, :partitioned}
      hub.pending_work_count > 0 -> {:error, :locked}
      true -> :ok
    end
  end

  defp do_drain(hub, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    Storage.insert(hub.storage.misc, StorageKey.drn(), %{waiter: self()})

    Enum.each(Cluster.nodes(hub.storage.misc), fn peer ->
      GenServer.cast(
        {hub.hub_id, peer},
        {:exec_cast, {__MODULE__, :handle_drain_distribution_removal, [node()]}}
      )
    end)

    handle_drain_distribution_removal(hub, node())
    local_count = map_size(ProcessRegistry.local_children(hub.hub_id))

    # Every local child now computes as "must move"; the normal redistribution
    # path migrates them through the consent gate.
    NodeUp.handle(%NodeUp{joined_nodes: [], hub: hub})

    forced =
      case await_drained(hub, deadline) do
        :drained -> 0
        :deadline -> run_pass(hub, :force).migrated
      end

    # The marker stays: a drained node must not re-announce its presence and be
    # pulled back into the distribution. Restart the hub to rejoin.
    Storage.insert(hub.storage.misc, StorageKey.drn(), %{waiter: nil})
    summary = %{migrated: max(local_count - forced, 0), forced: forced}
    HookManager.dispatch_hook(hub.storage.hook, Hook.drain_completed(), summary)

    {:ok, summary}
  end

  defp await_drained(hub, deadline) do
    wait = deadline - System.monotonic_time(:millisecond)

    cond do
      deferred_list(hub) === [] ->
        :drained

      wait <= 0 ->
        :deadline

      true ->
        receive do
          :ph_drain_deferred_empty -> await_drained(hub, deadline)
        after
          wait -> :deadline
        end
    end
  end

  defp notify_drain_waiter(hub) do
    case Storage.get(hub.storage.misc, StorageKey.drn()) do
      %{waiter: pid} when is_pid(pid) -> send(pid, :ph_drain_deferred_empty)
      _ -> :ok
    end
  end
end
