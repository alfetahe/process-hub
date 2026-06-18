defmodule ProcessHub.Service.Cluster do
  @moduledoc """
  `ProcessHub` instances with the same `hub_id` will automatically form a cluster.
  The cluster service provides API functions for managing the cluster.
  """

  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.State
  alias ProcessHub.Constant.Event
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Task.ClusterUpdateTask
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

  @doc """
  Sends `msg` to the locally-registered process `module` on every cluster node,
  including the local node.
  """
  @spec broadcast(module(), term()) :: :ok
  def broadcast(module, msg) do
    Enum.each([node() | Node.list()], fn n -> send({module, n}, msg) end)
    :ok
  end

  @doc "Promotes the current node to a cluster node."
  @spec promote_to_node(Hub.t(), node()) :: :ok | {:error, :not_alive}
  def promote_to_node(hub, node_name) do
    case Node.alive?() do
      false ->
        {:error, :not_alive}

      true ->
        Storage.insert(hub.storage.misc, StorageKey.hn(), [node_name])

        children = ProcessRegistry.dump_all(hub.hub_id)

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
  Handles the node down event by dispatching hooks, removing nodes from cluster state,
  and triggering the node down update task.
  """
  def handle_node_down(%{removed_nodes: removed_nodes, hub: hub}) do
    # Dispatch pre hooks for all nodes
    Enum.each(removed_nodes, fn n ->
      HookManager.dispatch_hook(hub.storage.hook, Hook.pre_node_leave(), %{node: n})
    end)

    # Remove nodes from cluster state first (serialized here in worker)
    Enum.each(removed_nodes, fn node ->
      rem_hub_node(hub.storage.misc, node)
    end)

    # Get updated hub_nodes AFTER removal
    updated_hub_nodes = nodes(hub.storage.misc, [:include_local])

    ClusterUpdateTask.NodeDown.handle(%ClusterUpdateTask.NodeDown{
      removed_nodes: removed_nodes,
      hub_nodes: updated_hub_nodes,
      hub: hub
    })
  end

  @doc """
  Removes every process-registry entry that references `node`, deleting any child
  entry left with no remaining locations. Returns the affected `child_id`s.

  This is a delete-only dead-node maintenance primitive for the cases the
  automatic `:nodedown` purge does not cover — for example `{dead_node, pid}`
  rows replayed from a durable registry at cold boot, where no `:nodedown` event
  ever fires. It does not redistribute; re-placement is the caller's job.
  """
  @spec purge_node(ProcessHub.hub_id(), node()) :: [ProcessHub.child_id()]
  def purge_node(hub_id, node) do
    purge_from(hub_id, ProcessRegistry.dump_all(hub_id), MapSet.new([node]))
  end

  @doc """
  Purges every node that is not part of the hub's current cluster from the
  process registry. Returns the list of purged dead nodes.

  Delete-only, like `purge_node/2`; it does not redistribute. Intended for
  out-of-band reconcile and cold-boot replay sanitisation.
  """
  @spec purge_dead_nodes(ProcessHub.hub_id()) :: [node()]
  def purge_dead_nodes(hub_id) do
    hub = ProcessHub.Coordinator.get_hub(hub_id)
    cluster_nodes = MapSet.new(nodes(hub.storage.misc, [:include_local]))
    registry = ProcessRegistry.dump_all(hub_id)

    dead_nodes =
      registry
      |> Enum.flat_map(fn {_child_id, {_spec, node_pids, _meta}} -> Keyword.keys(node_pids) end)
      |> Enum.uniq()
      |> Enum.reject(fn n -> MapSet.member?(cluster_nodes, n) end)

    purge_from(hub_id, registry, MapSet.new(dead_nodes))
    dead_nodes
  end

  # Single pass over an already-dumped registry: drop every `{node, pid}` whose
  # node is in `nodes_to_purge`, deleting entries left empty. Returns affected ids.
  defp purge_from(hub_id, registry, nodes_to_purge) do
    registry
    |> Enum.filter(fn {_child_id, {_spec, node_pids, _meta}} ->
      Enum.any?(node_pids, fn {node, _pid} -> MapSet.member?(nodes_to_purge, node) end)
    end)
    |> Enum.map(fn {child_id, {_spec, node_pids, _meta}} ->
      case Enum.reject(node_pids, fn {node, _pid} -> MapSet.member?(nodes_to_purge, node) end) do
        [] ->
          ProcessRegistry.delete(hub_id, child_id)

        remaining ->
          ProcessRegistry.update(hub_id, child_id, fn spec, _node_pids, meta ->
            {spec, remaining, meta}
          end)
      end

      child_id
    end)
  end

  @doc """
  Handles the node up event by dispatching hooks, adding nodes to cluster state,
  checking partition tolerance for quorum recovery, and triggering the node up update task.
  """
  def handle_node_up(%{joined_nodes: joined_nodes, hub: hub}) do
    # Dispatch pre hooks for all nodes
    Enum.each(joined_nodes, fn n ->
      HookManager.dispatch_hook(hub.storage.hook, Hook.pre_node_join(), %{node: n})
    end)

    # Add nodes to cluster state FIRST (consistent with handle_node_down)
    Enum.each(joined_nodes, fn node ->
      add_hub_node(hub.storage.misc, node)
    end)

    # Check if any node should trigger quorum recovery (AFTER adding)
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
  end
end
