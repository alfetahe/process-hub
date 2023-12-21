defmodule ProcessHub.Strategy.Distribution.ConsistentHashing do
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.LocalStorage
  alias ProcessHub.Service.Ring
  alias :hash_ring, as: HashRing

  @type t() :: %__MODULE__{}
  defstruct []

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.ConsistentHashing do
    @impl true
    @spec belongs_to(
            ProcessHub.Strategy.Distribution.ConsistentHashing.t(),
            atom(),
            atom() | binary(),
            [node()],
            pos_integer()
          ) :: [atom]
    def belongs_to(_strategy, hub_id, child_id, _hub_nodes, replication_factor) do
      LocalStorage.get(hub_id, :hash_ring)
      |> Ring.key_to_nodes(child_id, replication_factor)
    end

    # TODO: check if impl needs spec or not.
    @impl true
    def init(_strategy, hub_id, hub_nodes) do
      LocalStorage.insert(hub_id, :hub_nodes, HashRing.make(hub_nodes))
    end
  end
end
