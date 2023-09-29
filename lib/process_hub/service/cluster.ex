defmodule ProcessHub.Service.Cluster do
  @moduledoc """
  `ProcessHub` instances with the same `hub_id` will automatically form a cluster.
  The cluster service provides API functions for managing the cluster.
  """

  alias ProcessHub.Constant.Event
  alias ProcessHub.Utility.Name

  use Event

  @doc "Adds a new node to the cluster and returns the new list of nodes."
  @spec add_cluster_node([node()], node()) :: [node()]
  def add_cluster_node(nodes, node) do
    case Enum.member?(nodes, node) do
      true ->
        nodes

      false ->
        nodes ++ [node]
    end
  end

  @doc "Removes a node from the cluster and returns the new list of nodes."
  @spec rem_cluster_node([node()], node()) :: [node()]
  def rem_cluster_node(nodes, node) do
    Enum.filter(nodes, fn n -> n != node end)
  end

  @doc "Returns a boolean indicating whether the node exists in the cluster."
  @spec new_node?([node()], node()) :: boolean()
  def new_node?(nodes, node) do
    !Enum.member?(nodes, node)
  end

  @doc "Returns a list of nodes in the cluster."
  @spec nodes(ProcessHub.hub_id(), [:include_local] | nil) :: [node()]
  def nodes(hub_id, opts \\ []) do
    nodes = GenServer.call(Name.coordinator(hub_id), :cluster_nodes)

    case Enum.member?(opts, :include_local) do
      false -> Enum.filter(nodes, &(&1 !== node()))
      true -> nodes
    end
  end

  @doc "Sends a cluster join event to the remote node."
  @spec propagate_self(ProcessHub.hub_id(), node()) :: term()
  def propagate_self(hub_id, node) do
    local_node = node()
    coordinator = Name.coordinator(hub_id)

    :erlang.send({coordinator, node}, {@event_cluster_join, local_node})
  end
end
