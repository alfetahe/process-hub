defmodule ProcessHub.WorkerQueue do
  alias ProcessHub.Service.{HookManager, State}
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Request.CrossNodeRequest
  alias ProcessHub.Task.ClusterUpdateTask
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Storage

  use GenServer

  def start_link({hub_id, pname, misc_storage}) do
    GenServer.start_link(__MODULE__, {hub_id, misc_storage}, name: pname)
  end

  @impl true
  def init({hub_id, _misc_storage}) do
    {:ok, %{hub_id: hub_id}}
  end

  @impl true
  def handle_cast({:handle_work, func}, state) do
    func.()

    {:noreply, state}
  end

  @impl true
  def handle_cast({:handle_requests, requests, hub}, state) do
    Task.async_stream(requests, &CrossNodeRequest.handle(&1, hub),
      timeout: Storage.get(hub.storage.misc, StorageKey.cnrt()) || 5000,
      ordered: false,
      on_timeout: :kill_task
    )
    |> Stream.run()

    {:noreply, state}
  end

  @impl true
  def handle_cast({:handle_node_down, %{removed_nodes: removed_nodes, hub: hub} = _arg}, state) do
    # Dispatch pre hooks for all nodes
    Enum.each(removed_nodes, fn n ->
      HookManager.dispatch_hook(hub.storage.hook, Hook.pre_cluster_leave(), n)
    end)

    # Remove nodes from cluster state first (serialized here in worker)
    Enum.each(removed_nodes, fn node ->
      Cluster.rem_hub_node(hub.storage.misc, node)
    end)

    # Get updated hub_nodes AFTER removal
    updated_hub_nodes = Cluster.nodes(hub.storage.misc, [:include_local])

    ClusterUpdateTask.NodeDown.handle(%ClusterUpdateTask.NodeDown{
      removed_nodes: removed_nodes,
      hub_nodes: updated_hub_nodes,
      hub: hub
    })

    {:noreply, state}
  end

  @impl true
  def handle_cast({:handle_node_up, %{joined_nodes: joined_nodes, hub: hub} = _arg}, state) do
    # Dispatch pre hooks for all nodes
    Enum.each(joined_nodes, fn n ->
      HookManager.dispatch_hook(hub.storage.hook, Hook.pre_cluster_join(), n)
    end)

    # Add nodes to cluster state FIRST (consistent with handle_node_down)
    Enum.each(joined_nodes, fn node ->
      Cluster.add_hub_node(hub.storage.misc, node)
    end)

    # Check if any node should trigger quorum unlock (AFTER adding)
    part_strat = Storage.get(hub.storage.misc, StorageKey.strpart())

    unlock_status =
      Enum.any?(joined_nodes, fn n ->
        PartitionToleranceStrategy.toggle_unlock?(part_strat, hub, n)
      end)

    if unlock_status do
      State.toggle_quorum_success(hub)
    end

    ClusterUpdateTask.NodeUp.handle(%ClusterUpdateTask.NodeUp{
      joined_nodes: joined_nodes,
      hub: hub
    })

    {:noreply, state}
  end

  @impl true
  def handle_call({:handle_work, func}, _from, state) do
    {:reply, func.(), state}
  end
end
