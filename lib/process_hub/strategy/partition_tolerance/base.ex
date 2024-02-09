defprotocol ProcessHub.Strategy.PartitionTolerance.Base do
  @moduledoc """
  The partition tolerance strategy protocol defines the behavior for handling
  node up and down events in the `ProcessHub` cluster.
  """

  @doc """
  Triggered when coordinator is initialized.

  Could be used to perform initialization.
  """
  @spec init(struct(), ProcessHub.hub_id()) :: any()
  def init(strategy, hub_id)

  @doc """
  This function is called when a new node joins the `ProcessHub` cluster.
  """
  @spec handle_node_up(__MODULE__.t(), ProcessHub.hub_id(), node()) :: :ok
  def handle_node_up(strategy, hub_id, node)

  @doc """
  This function is called when a new node leaves the `ProcessHub` cluster.
  """
  @spec handle_node_down(__MODULE__.t(), ProcessHub.hub_id(), node()) :: :ok
  def handle_node_down(strategy, hub_id, node)
end
