defmodule Test.Support.RecordingPartition do
  @moduledoc """
  A partition tolerance strategy that never locks and tells `recorder` every
  departure it is asked about, as `{:toggle_lock, reporting_node, node, kind}`,
  so a test can see which departures reach the strategy and how they are told.
  """

  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy

  defstruct [:recorder]

  defimpl PartitionToleranceStrategy do
    def validate(_strategy), do: :ok
    def init(strategy, _hub), do: strategy

    def toggle_lock?(strategy, _hub, down_node, kind) do
      send(strategy.recorder, {:toggle_lock, node(), down_node, kind})
      false
    end

    def toggle_unlock?(_strategy, _hub, _up_node), do: false
  end
end
