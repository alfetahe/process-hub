defmodule ProcessHub.Service.Cluster do
  @moduledoc """
  `ProcessHub` instances with the same `hub_id` will automatically form a cluster.
  The cluster service provides API functions for managing the cluster.
  """

  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.Event
  alias ProcessHub.Constant.StorageKey
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

  @doc "Sends a cluster join event to the remote node."
  @spec propagate_self(atom(), node()) :: term()
  def propagate_self(event_queue, node) do
    Dispatcher.propagate_event(event_queue, @event_cluster_join, node(), %{members: [node]})
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
end
