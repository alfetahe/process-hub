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
  Determines if the lock should be toggled when a node leaves the cluster.
  """
  @spec toggle_lock?(__MODULE__.t(), ProcessHub.hub_id(), node()) :: boolean()
  def toggle_lock?(strategy, hub_id, down_node)

  @doc """
  Determines if the lock should be released when a node joins the cluster.
  """
  @spec toggle_unlock?(__MODULE__.t(), ProcessHub.hub_id(), node()) :: boolean()
  def toggle_unlock?(strategy, hub_id, down_node)
end
