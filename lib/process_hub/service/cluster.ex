defmodule ProcessHub.Service.Cluster do
  @moduledoc """
  `ProcessHub` instances with the same `hub_id` will automatically form a cluster.
  The cluster service provides API functions for managing the cluster.
  """

  alias ProcessHub.Service.{ProcessRegistry, Synchronizer}
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.{HookManager, State}
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Constant.Event
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Hub

  use Event

  @doc "Adds a new node to the hub cluster and returns new list of nodes."
  @spec add_hub_node(:ets.tid(), node()) :: [node()]
  def add_hub_node(misc_storage, node) do
    hub_nodes = Storage.get(misc_storage, StorageKey.hn())

    hub_nodes =
      case Enum.member?(hub_nodes, node) do
        true ->
          hub_nodes

        false ->
          hub_nodes ++ [node]
      end

    Storage.insert(misc_storage, StorageKey.hn(), hub_nodes)

    hub_nodes
  end

  @doc "Removes a node from the cluster and returns new list of nodes."
  @spec rem_hub_node(:ets.tid(), node()) :: [node()]
  def rem_hub_node(misc_storage, node) do
    hub_nodes = Storage.get(misc_storage, StorageKey.hn())
    hub_nodes = Enum.filter(hub_nodes, fn n -> n != node end)
    Storage.insert(misc_storage, StorageKey.hn(), hub_nodes)

    hub_nodes
  end

  @doc "Returns a boolean indicating whether the node exists in the cluster."
  @spec new_node?([node()], node()) :: boolean()
  def new_node?(nodes, node) do
    !Enum.member?(nodes, node)
  end

  @doc "Returns a list of nodes in the cluster."
  @spec nodes(:ets.tid(), [:include_local] | nil) :: [node()]
  def nodes(misc_storage, opts \\ []) do
    nodes = Storage.get(misc_storage, StorageKey.hn()) || []

    case Enum.member?(opts, :include_local) do
      false -> Enum.filter(nodes, &(&1 !== node()))
      true -> nodes
    end
  end

  @doc "Promotes the current node to a cluster node."
  @spec promote_to_node(Hub.t(), node()) :: :ok | {:error, :not_alive}
  def promote_to_node(hub, node_name) do
    case Node.alive?() do
      false ->
        {:error, :not_alive}

      true ->
        Storage.insert(hub.storage.misc, StorageKey.hn(), [node_name])

        children = ProcessRegistry.dump(hub.hub_id)

        Enum.each(children, fn {_child_id, {child_spec, node_pids, metadata}} ->
          new_node_pids = Enum.map(node_pids, fn {_node, pid} -> {node_name, pid} end)

          ProcessRegistry.insert(
            hub.hub_id,
            child_spec,
            new_node_pids,
            metadata: metadata
          )
        end)

        :ok
    end
  end

  @doc """
  Handles nodes joining the ProcessHub cluster.

  Filters new nodes, broadcasts local registry data, dispatches pre_cluster_join hooks,
  checks partition tolerance for quorum unlock, and casts `{:handle_node_up, ...}` to worker_queue.
  """
  @spec process_hub_join(Hub.t(), [node()]) :: Hub.t()
  def process_hub_join(state, nodes) do
    hub_nodes = nodes(state.storage.misc, [:include_local])
    local_node = node()

    # Filter to only new nodes.
    new_nodes =
      Enum.filter(nodes, fn n ->
        new_node?(hub_nodes, n) and n !== local_node
      end)

    if length(new_nodes) > 0 do
      # Broadcast local registry data to joining nodes
      Synchronizer.broadcast_local_registry(state, new_nodes)

      # Dispatch pre hooks for all nodes
      Enum.each(new_nodes, fn n ->
        HookManager.dispatch_hook(state.storage.hook, Hook.pre_cluster_join(), n)
      end)

      # Check if any node should trigger quorum unlock
      part_strat = Storage.get(state.storage.misc, StorageKey.strpart())

      unlock_status =
        Enum.any?(new_nodes, fn n ->
          PartitionToleranceStrategy.toggle_unlock?(part_strat, state, n)
        end)

      # TODO: remove
      if unlock_status do
        State.toggle_quorum_success(state)
      end

      GenServer.cast(
        state.procs.worker_queue,
        {:handle_node_up,
         %{
           joined_nodes: new_nodes,
           hub: state
         }}
      )
    end

    state
  end

  @doc """
  Handles a single node leaving the cluster.

  Checks if the node is in the hub, dispatches pre_cluster_leave hook,
  and casts `{:handle_node_down, ...}` to worker_queue.
  """
  @spec process_node_down(Hub.t(), node()) :: Hub.t()
  def process_node_down(state, down_node) do
    hub_nodes = nodes(state.storage.misc, [:include_local])

    if Enum.member?(hub_nodes, down_node) do
      HookManager.dispatch_hook(state.storage.hook, Hook.pre_cluster_leave(), down_node)

      GenServer.cast(
        state.procs.worker_queue,
        {:handle_node_down,
         %{
           removed_nodes: [down_node],
           hub: state,
           hook_storage: state.storage.hook
         }}
      )
    else
      # TODO: remove.
      # Node not in hub - unlock immediately since we locked at dispatch time
      State.unlock_event_handler(state)
    end

    state
  end

  @doc """
  Handles a batch of nodes leaving the cluster.

  Filters to nodes actually in the hub, dispatches pre_cluster_leave hooks,
  and casts a single `{:handle_node_down, ...}` to worker_queue.
  """
  @spec process_node_down_batch(Hub.t(), [node()]) :: Hub.t()
  def process_node_down_batch(state, down_nodes) do
    hub_nodes = nodes(state.storage.misc, [:include_local])

    # Filter to only nodes that are actually in the hub
    valid_down_nodes = Enum.filter(down_nodes, &Enum.member?(hub_nodes, &1))

    if length(valid_down_nodes) > 0 do
      # Dispatch pre hooks for all nodes
      Enum.each(valid_down_nodes, fn n ->
        HookManager.dispatch_hook(state.storage.hook, Hook.pre_cluster_leave(), n)
      end)

      GenServer.cast(
        state.procs.worker_queue,
        {:handle_node_down,
         %{
           removed_nodes: valid_down_nodes,
           hub: state,
           hook_storage: state.storage.hook
         }}
      )
    end

    state
  end
end
