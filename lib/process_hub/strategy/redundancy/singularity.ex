defmodule ProcessHub.Strategy.Redundancy.Singularity do
  @moduledoc """
  The Singularity strategy starts a single instance of a process and creates no replicas on
  other nodes. This is the default strategy.
  """

  alias ProcessHub.Hub
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy

  @typedoc """
  No options are available.
  """
  @type t() :: %__MODULE__{}
  defstruct []

  defimpl RedundancyStrategy, for: ProcessHub.Strategy.Redundancy.Singularity do
    @impl true
    def init(strategy, _hub), do: strategy

    @impl true
    @spec replication_factor(ProcessHub.Strategy.Redundancy.Singularity.t()) :: 1
    def replication_factor(_strategy), do: 1

    @impl true
    @spec master_node(struct(), Hub.t(), ProcessHub.child_id(), [node()]) :: node()
    def master_node(_strategy, _hub, _child_id, child_nodes) do
      List.first(child_nodes)
    end
  end
end
