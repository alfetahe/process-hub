defmodule ProcessHub.Strategy.Distribution.ConsistentHashing do
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.LocalStorage
  alias ProcessHub.Service.Ring

  @type t() :: %__MODULE__{}
  defstruct []

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.ConsistentHashing do
    @impl true
    @spec children_init(struct(), atom(), [map()], keyword()) :: :ok | {:error, any()}
    def children_init(_strategy, _hub_id, _child_specs, _opts), do: :ok

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

    @impl true
    def init(_strategy, hub_id, hub_nodes) do
      LocalStorage.insert(hub_id, Ring.storage_key(), Ring.create_ring(hub_nodes))
    end

    @impl true
    @spec node_join(struct(), atom(), [node()], node()) :: any()
    def node_join(_strategy, hub_id, _hub_nodes, node) do
      hash_ring = Ring.get_ring(hub_id) |> Ring.add_node(node)

      LocalStorage.insert(hub_id, Ring.storage_key(), hash_ring)
    end

    @impl true
    @spec node_leave(struct(), atom(), [node()], node()) :: any()
    def node_leave(_strategy, hub_id, _hub_nodes, node) do
      hash_ring = Ring.get_ring(hub_id) |> Ring.remove_node(node)

      LocalStorage.insert(hub_id, Ring.storage_key(), hash_ring)
    end
  end
end
