defmodule ProcessHub.Strategy.Redundancy.Singularity do
  @moduledoc """
  The Singularity strategy starts a single instance of a process and creates no replicas on
  other nodes. This is the default strategy.
  """

  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy

  @typedoc """
  No options are available.
  """
  @type t() :: %__MODULE__{}
  defstruct []

  defimpl RedundancyStrategy, for: ProcessHub.Strategy.Redundancy.Singularity do
    @impl true
    @spec replication_factor(ProcessHub.Strategy.Redundancy.Singularity.t()) :: 1
    def replication_factor(_strategy), do: 1

    @impl true
    @spec handle_post_start(
            ProcessHub.Strategy.Redundancy.Singularity.t(),
            atom(),
            atom() | binary(),
            pid(),
            [node()]
          ) :: :ok
    def handle_post_start(_strategy, _hub_id, _child_id, _child_pid, _hub_nodes), do: :ok

    @impl true
    @spec handle_post_update(
            ProcessHub.Strategy.Redundancy.Singularity.t(),
            ProcessHub.hub_id(),
            atom() | binary(),
            [node()],
            {:up | :down, node()}
          ) :: :ok
    def handle_post_update(_strategy, _hub_id, _child_id, _hub_nodes, _action_node), do: :ok
  end
end
