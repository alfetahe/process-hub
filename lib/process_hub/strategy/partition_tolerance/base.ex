defprotocol ProcessHub.Strategy.PartitionTolerance.Base do
  alias ProcessHub.Hub

  @moduledoc """
  The partition tolerance strategy protocol defines the behavior for handling
  node up and down events in the `ProcessHub` cluster.
  """

  @doc """
  Checks the strategy's settings before the hub starts.
  """
  @spec validate(struct()) :: :ok | {:error, {:invalid_config, term()}}
  def validate(strategy)

  @doc """
  Triggered when coordinator is initialized.

  Could be used to perform initialization.
  """
  @spec init(struct(), Hub.t()) :: struct()
  def init(strategy, hub)

  @doc """
  Determines if a quorum failure should be triggered when a node leaves the cluster.

  `kind` is `:leave` when the node announced its departure or drained, so it was
  reachable when it went and cannot be on the other side of a split, and `:down`
  when it disappeared without either.
  """
  @spec toggle_lock?(__MODULE__.t(), Hub.t(), node(), :down | :leave) :: boolean()
  def toggle_lock?(strategy, hub, down_node, kind)

  @doc """
  Determines if a quorum recovery should be triggered when a node joins the cluster.
  """
  @spec toggle_unlock?(__MODULE__.t(), Hub.t(), node()) :: boolean()
  def toggle_unlock?(strategy, hub, down_node)
end
