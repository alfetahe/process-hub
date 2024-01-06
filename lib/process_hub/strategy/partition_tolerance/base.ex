defprotocol ProcessHub.Strategy.PartitionTolerance.Base do
  @moduledoc """
  The partition tolerance strategy protocol defines the behavior for handling
  node up and down events in the `ProcessHub` cluster.
  """

  @doc """
  This function is called when a new node joins the `ProcessHub` cluster.
  """
  @spec handle_node_up(__MODULE__.t(), ProcessHub.hub_id(), node(), [node()]) :: :ok
  def handle_node_up(strategy, hub_id, node, cluster_nodes)

  @doc """
  This function is called when a new node leaves the `ProcessHub` cluster.
  """
  @spec handle_node_down(__MODULE__.t(), ProcessHub.hub_id(), node(), [node()]) :: :ok
  def handle_node_down(strategy, hub_id, node, cluster_nodes)

  @doc """
  This function is called when `ProcessHub` is starting up.
  """
  @spec handle_startup(__MODULE__.t(), ProcessHub.hub_id()) :: :ok
  def handle_startup(strategy, hub_id)
end
