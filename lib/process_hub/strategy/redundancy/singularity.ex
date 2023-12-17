defmodule ProcessHub.Strategy.Redundancy.Singularity do
  @moduledoc """
  The Singularity strategy starts a single instance of a process and creates no replicas on
  other nodes. This is the default strategy.
  """

  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Service.Ring

  @typedoc """
  No options are available.
  """
  @type t() :: %__MODULE__{}
  defstruct []

  defimpl RedundancyStrategy, for: ProcessHub.Strategy.Redundancy.Singularity do
    @impl true
    @spec replication_factor(ProcessHub.Strategy.Redundancy.Singularity.t()) :: 1
    def replication_factor(_struct), do: 1

    @impl true
    @spec handle_post_start(
            ProcessHub.Strategy.Redundancy.Singularity.t(),
            ProcessHub.Strategy.Distribution.HashRing.t(),
            atom() | binary(),
            pid()
          ) :: :ok
    def handle_post_start(_struct, _dist_strategy, _child_id, _child_pid), do: :ok

    @impl true
    @spec handle_post_update(
            ProcessHub.Strategy.Redundancy.Singularity.t(),
            ProcessHub.hub_id(),
            atom() | binary(),
            term()
          ) :: :ok
    def handle_post_update(_struct, _hub_id, _child_id, _data), do: :ok
  end
end
