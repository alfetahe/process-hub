defmodule ProcessHub.Strategy.Distribution.ConsistentHashing do
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.Ring
  alias :hash_ring, as: HashRing

  @type t() :: %__MODULE__{
          hash_ring: HashRing.ring()
        }

  defstruct [:hash_ring]

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.ConsistentHashing do
    @impl true
    @spec belongs_to(
            ProcessHub.Strategy.Distribution.ConsistentHashing.t(),
            atom() | binary()
          ) :: [atom]
    def belongs_to(strategy, child_id, replication_factor) do
      Ring.key_to_nodes(strategy.hash_ring, child_id, replication_factor)
    end
  end
end
