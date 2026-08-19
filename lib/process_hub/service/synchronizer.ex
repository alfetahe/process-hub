defmodule ProcessHub.Service.Synchronizer do
  @moduledoc """
  The synchronizer service provides API functions for synchronizing process
  registry data between nodes.
  """

  alias ProcessHub.Coordinator
  alias ProcessHub.Task.SynchronizationTask
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.ProcessRegistry.Row
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Hub

  @doc """
  Helper function to trigger interval synchronization.

  The system will use the configured synchronization strategy.
  """
  def trigger_sync(hub) do
    Task.Supervisor.async(
      hub.procs.task_sup,
      SynchronizationTask.IntervalSyncInit,
      :handle,
      [
        %SynchronizationTask.IntervalSyncInit{
          hub: hub
        }
      ]
    )
    |> Task.await()
  end

  def exec_interval_sync(hub_id, strategy, sync_data, remote_node) do
    hub = Coordinator.get_hub(hub_id)

    Task.Supervisor.async_nolink(
      hub.procs.task_sup,
      SynchronizationTask.IntervalSyncHandle,
      :handle,
      [
        %SynchronizationTask.IntervalSyncHandle{
          hub: hub,
          sync_strat: strategy,
          sync_data: sync_data,
          remote_node: remote_node
        }
      ]
    )
    |> Task.await()
  end

  @doc """
  Returns the local node's process registry data used for synchronization.

  Carries the children bound locally, each reported with the pid this node
  observes — a bound row travels with its holder. Stop knowledge does not travel
  here: for declared children it lives in the declared list, and unbound rows
  are deliberately not carried, because peers cannot act on them.
  """
  @spec local_sync_data(Hub.t()) :: [
          {ProcessHub.child_spec(), pid(), ProcessHub.child_metadata()}
        ]
  def local_sync_data(hub) do
    local_node = node()

    ProcessRegistry.dump_all(hub.hub_id)
    |> Enum.reduce([], fn {_child_id, {child_spec, child_nodes, metadata}}, acc ->
      case Keyword.get(child_nodes, local_node) do
        nil -> acc
        pid -> [{child_spec, pid, metadata} | acc]
      end
    end)
  end

  @doc """
  Merges a peer's registry rows into the local process registry.

  The row itself — child spec, caller metadata, and hub bookkeeping — resolves by
  higher epoch, ties broken by the lexicographically lower authoring node name, so
  every node converges on the same value in any order and with any number of
  repetitions. The winner is adopted verbatim: a merge does not author a row and
  never increments an epoch.

  `node_pids` is not part of that resolution. A payload from node `N` carries
  observations `N` owns, so only the `{N, pid}` entry is touched; entries owned by
  any other node are left alone.
  """
  @spec append_data(Hub.t(), %{
          node() => [{ProcessHub.child_spec(), pid(), ProcessHub.child_metadata()}]
        }) :: :ok
  def append_data(hub, remote_data) do
    Enum.each(remote_data, fn {remote_node, remote_children} ->
      Enum.each(remote_children, fn {remote_cs, remote_pid, remote_meta} ->
        merge_row(hub, remote_node, remote_cs, remote_pid, remote_meta)
      end)
    end)
  end

  defp merge_row(hub, remote_node, remote_cs, remote_pid, remote_meta) do
    case ProcessRegistry.lookup(hub.hub_id, remote_cs.id,
           with_metadata: true,
           include_empty: true
         ) do
      nil ->
        ProcessRegistry.insert(
          hub.hub_id,
          remote_cs,
          observe([], remote_node, remote_pid),
          hook_storage: hub.storage.hook,
          metadata: remote_meta,
          adopt: true
        )

      {local_cs, local_child_nodes, local_meta} ->
        {child_spec, metadata} =
          if Row.wins_merge?(remote_meta, local_meta) do
            {remote_cs, remote_meta}
          else
            {local_cs, local_meta}
          end

        child_nodes = observe(local_child_nodes, remote_node, remote_pid)

        if child_nodes !== local_child_nodes or metadata !== local_meta or
             child_spec !== local_cs do
          ProcessRegistry.insert(hub.hub_id, child_spec, child_nodes,
            hook_storage: hub.storage.hook,
            metadata: metadata,
            adopt: true
          )
        end
    end
  end

  # A node owns exactly its own entry: a reported pid sets it, a `nil` pid (the
  # node holds the row but runs nothing for it) clears it.
  defp observe(child_nodes, node, nil), do: Keyword.delete(child_nodes, node)
  defp observe(child_nodes, node, pid), do: Keyword.put(child_nodes, node, pid)

  @doc """
  Withdraws a peer's observations for children its payload does not mention.

  Absence is an observation, never an authority: a child missing from node `N`'s
  payload drops only the `{N, pid}` entry. The row survives an emptied node list —
  it becomes a candidate for the next orphan reconcile round instead of being
  deleted, so a peer reporting a partial or empty registry can never erase durable
  state on any other node.
  """
  @spec detach_data(Hub.t(), %{node() => [{ProcessHub.child_spec(), pid()}]}) :: :ok
  def detach_data(hub, remote_children) do
    ProcessRegistry.withdraw_observations(
      hub.hub_id,
      ProcessRegistry.dump_all(hub.hub_id),
      fn child_id, node -> withdrawn?(remote_children[node], child_id) end,
      hook_storage: hub.storage.hook
    )

    :ok
  end

  # A node that sent no payload at all made no observation, so it withdraws
  # nothing.
  defp withdrawn?(nil, _child_id), do: false

  defp withdrawn?(reported_children, child_id) do
    not Enum.any?(reported_children, fn {cs, _pid, _m} -> cs.id == child_id end)
  end

  @doc """
  Returns `{:ok, data}` to broadcast, or `:suppress`.

  A node that has hosted no local child since boot returns an empty
  `local_sync_data/1`; broadcasting it would make peers' `detach_data/2` treat
  the node as authoritatively empty and wipe its records. We suppress that empty
  until the node has hosted a child at least once (latched in `storage.misc`,
  which resets on restart). A node that legitimately drained its children is
  already latched, so it still broadcasts its empty and peers reconcile.
  """
  @spec broadcastable_local_data(Hub.t()) ::
          {:ok, [{ProcessHub.child_spec(), pid(), ProcessHub.child_metadata()}]} | :suppress
  def broadcastable_local_data(hub) do
    case local_sync_data(hub) do
      [] ->
        if Storage.get(hub.storage.misc, StorageKey.rp()) === true, do: {:ok, []}, else: :suppress

      data ->
        Storage.insert(hub.storage.misc, StorageKey.rp(), true)
        {:ok, data}
    end
  end

  @doc """
  Broadcasts local registry data to the specified target nodes.

  Called when new nodes join the cluster to share local process information.
  """
  @spec broadcast_local_registry(Hub.t(), [node()]) :: :ok
  def broadcast_local_registry(state, target_nodes) do
    case broadcastable_local_data(state) do
      :suppress ->
        :ok

      {:ok, local_data} ->
        sync_strategy = Storage.get(state.storage.misc, StorageKey.strsyn())

        SynchronizationStrategy.broadcast_local_data(
          sync_strategy,
          state,
          local_data,
          target_nodes
        )
    end
  end
end
