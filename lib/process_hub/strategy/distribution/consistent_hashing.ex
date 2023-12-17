defmodule ProcessHub.Strategy.Distribution.ConsistentHashing do
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Service.Ring
  alias :hash_ring, as: HashRing

  @type t() :: %__MODULE__{
          hash_ring: HashRing.ring(),
          redundancy_strategy: RedundancyStrategy.t()
        }

  @enforce_keys [:hash_ring, :redundancy_strategy]

  defstruct @enforce_keys

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.ConsistentHashing do
    @impl true
    @spec belongs_to(
            ProcessHub.Strategy.Distribution.ConsistentHashing.t(),
            atom() | binary()
          ) :: [atom]
    def belongs_to(strategy, child_id) do
      Ring.key_to_nodes(
        strategy.hash_ring,
        child_id,
        RedundancyStrategy.replication_factor(strategy.redundancy_strategy)
      )
    end
  end
end
