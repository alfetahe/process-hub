defmodule ProcessHub.WorkerQueue do
  alias ProcessHub.Request.CrossNodeRequest
  alias ProcessHub.Handler.ClusterUpdate
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Storage
  alias ProcessHub.Future

  use GenServer

  def start_link({hub_id, pname, misc_storage}) do
    GenServer.start_link(__MODULE__, {hub_id, misc_storage}, name: pname)
  end

  @impl true
  def init({hub_id, misc_storage}) do
    handle_static_children(hub_id, misc_storage)

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
  def handle_cast({:handle_node_down, params}, state) do
    # Remove nodes from cluster state first (serialized here in worker)
    Enum.each(params.removed_nodes, fn node ->
      Cluster.rem_hub_node(params.hub.storage.misc, node)
    end)

    # Get updated hub_nodes AFTER removal
    updated_hub_nodes = Cluster.nodes(params.hub.storage.misc, [:include_local])

    ClusterUpdate.NodeDown.handle(%ClusterUpdate.NodeDown{
      removed_nodes: params.removed_nodes,
      hub_nodes: updated_hub_nodes,
      hub: params.hub
    })

    Enum.each(params.removed_nodes, fn node ->
      HookManager.dispatch_hook(params.hook_storage, Hook.post_cluster_leave(), %{
        removed_node: node
      })
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:handle_node_up, params}, state) do
    # Add nodes to cluster state first (serialized here in worker)
    Enum.each(params.joined_nodes, fn node ->
      Cluster.add_hub_node(params.hub.storage.misc, node)
    end)

    ClusterUpdate.NodeUp.handle(%ClusterUpdate.NodeUp{
      joined_nodes: params.joined_nodes,
      hub: params.hub
    })

    {:noreply, state}
  end

  @impl true
  def handle_call({:handle_work, func}, _from, state) do
    {:reply, func.(), state}
  end

  defp handle_static_children(hub_id, misc_storage) do
    static_child_specs = Storage.get(misc_storage, StorageKey.staticcs())

    if length(static_child_specs) > 0 do
      res =
        ProcessHub.start_children(
          hub_id,
          static_child_specs,
          awaitable: true
        )
        |> Future.await()

      case res.status do
        :ok -> nil
        :error -> raise RuntimeError, message: "static children startup failed."
      end
    end
  end
end
