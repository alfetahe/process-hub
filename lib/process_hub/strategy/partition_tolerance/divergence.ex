defmodule ProcessHub.Strategy.PartitionTolerance.Divergence do
  @moduledoc """
  The divergence strategy for partition tolerance is used when the `ProcessHub` cluster is not
  concerned with partition failures.

  When a node leaves or joins the `ProcessHub` cluster, the divergence strategy keeps the `ProcessHub`
  running no matter what.

  > #### `In case of network partition` {: .info}
  > The divergence strategy does not handle network partitions in any way. When a network
  > partition occurs, the `ProcessHub` cluster will continue to run on both sides of the partition.

  This is the default strategy for partition tolerance.
  """

  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy

  @typedoc """
  Divergence strategy configuration.
  """
  @type t :: %__MODULE__{}
  defstruct []

  defimpl PartitionToleranceStrategy, for: ProcessHub.Strategy.PartitionTolerance.Divergence do
    @impl true
    def init(_strategy, _hub), do: nil

    @impl true
    def toggle_unlock?(_strategy, _hub, _up_node), do: false

    @impl true
    def toggle_lock?(_strategy, _hub, _down_node), do: false
  end
end
