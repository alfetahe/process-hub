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
    def init(_strategy, _hub_id), do: nil

    @impl true
    def handle_node_down(_strategy, _hub_id, _node), do: :ok

    @impl true
    def handle_node_up(_strategy, _hub_id, _node), do: :ok
  end
end
