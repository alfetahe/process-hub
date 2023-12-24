defmodule ProcessHub.Strategy.Distribution.ConsistentHashing do
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.LocalStorage
  alias ProcessHub.Service.Ring
  alias ProcessHub.Utility.Name

  @type t() :: %__MODULE__{}
  defstruct []

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.ConsistentHashing do
    @impl true
    @spec belongs_to(
            ProcessHub.Strategy.Distribution.ConsistentHashing.t(),
            atom(),
            atom() | binary(),
            pos_integer()
          ) :: [atom]
    def belongs_to(_strategy, hub_id, child_id, replication_factor) do
      Ring.get_ring(hub_id) |> Ring.key_to_nodes(child_id, replication_factor)
    end

    # TODO: check if impl needs spec or not.
    @impl DistributionStrategy
    def init(_strategy, hub_id, hub_nodes) do
      Name.local_storage(hub_id)
      |> LocalStorage.insert(Ring.storage_key(), Ring.create_ring(hub_nodes))
    end

    # TODO: add documentation
    @impl DistributionStrategy
    def node_join(_strategy, hub_id, _hub_nodes, node) do
      hash_ring = Ring.get_ring(hub_id) |> Ring.add_node(node)

      Name.local_storage(hub_id)
      |> LocalStorage.insert(Ring.storage_key(), hash_ring)
    end

    # TODO: add documentation
    @impl DistributionStrategy
    def node_leave(_strategy, hub_id, _hub_nodes, node) do
      hash_ring = Ring.get_ring(hub_id) |> Ring.remove_node(node)

      Name.local_storage(hub_id)
      |> LocalStorage.insert(Ring.storage_key(), hash_ring)
    end
  end
end
