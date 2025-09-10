defprotocol ProcessHub.Strategy.PartitionTolerance.Base do
  alias ProcessHub.Hub

  @moduledoc """
  The partition tolerance strategy protocol defines the behavior for handling
  node up and down events in the `ProcessHub` cluster.
  """

  @doc """
  Triggered when coordinator is initialized.

  Could be used to perform initialization.
  """
  @spec init(struct(), Hub.t()) :: struct()
  def init(strategy, hub)

  @doc """
  Determines if the lock should be toggled when a node leaves the cluster.
  """
  @spec toggle_lock?(__MODULE__.t(), Hub.t(), node()) :: boolean()
  def toggle_lock?(strategy, hub, down_node)

  @doc """
  Determines if the lock should be released when a node joins the cluster.
  """
  @spec toggle_unlock?(__MODULE__.t(), Hub.t(), node()) :: boolean()
  def toggle_unlock?(strategy, hub, down_node)
end
