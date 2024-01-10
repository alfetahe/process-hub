defmodule ProcessHub.Strategy.Distribution.ConsistentHashing do
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.LocalStorage
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Ring
  alias ProcessHub.Constant.Hook

  @type t() :: %__MODULE__{}
  defstruct []

  @spec handle_node_join(atom(), node()) :: any()
  def handle_node_join(hub_id, node) do
    hash_ring = Ring.get_ring(hub_id) |> Ring.add_node(node)

    LocalStorage.insert(hub_id, Ring.storage_key(), hash_ring)
  end

  @spec handle_node_leave(atom(), node()) :: any()
  def handle_node_leave(hub_id, node) do
    hash_ring = Ring.get_ring(hub_id) |> Ring.remove_node(node)

    LocalStorage.insert(hub_id, Ring.storage_key(), hash_ring)
  end

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
    def init(_strategy, hub_id) do
      hub_nodes = LocalStorage.get(hub_id, :hub_nodes)

      LocalStorage.insert(hub_id, Ring.storage_key(), Ring.create_ring(hub_nodes))

      join_handler = {
        ProcessHub.Strategy.Distribution.ConsistentHashing,
        :handle_node_join,
        [hub_id, :_]
      }

      leave_handler = {
        ProcessHub.Strategy.Distribution.ConsistentHashing,
        :handle_node_leave,
        [hub_id, :_]
      }

      HookManager.register_hook_handlers(hub_id, Hook.pre_cluster_join(), [join_handler])
      HookManager.register_hook_handlers(hub_id, Hook.pre_cluster_leave(), [leave_handler])
    end
  end
end
