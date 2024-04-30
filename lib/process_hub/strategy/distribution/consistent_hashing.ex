defmodule ProcessHub.Strategy.Distribution.ConsistentHashing do
  @moduledoc """
  Provides implementation for distribution behaviour using consistent hashing.

  This strategy uses consistent hashing to determine the nodes and child processes
  mapping.

  The consensus is achieved in the cluster by creating a hash ring. The hash ring
  is a ring of nodes where each node is responsible for a range of hash values.
  The hash value of a child process is used to determine which node is responsible
  for the child process.

  When the cluster is updated, the hash ring is recalculated.
  The recalculation is done in a way that each node is assigned a unique
  hash value, and they form a **hash ring**. Each node in the cluster keeps track of
  the ProcessHub cluster and updates its local hash ring accordingly.

  To find the node that the process belongs to, the system will use the hash ring to calculate
  the hash value of the process ID (`child_id`) and assign it to the node with the closest hash value.

  When the cluster is updated and the hash ring is recalculated, it does not mean that all
  processes will be shuffled. Only the processes that are affected by the change will
  be redistributed. This is done to avoid unnecessary process migrations.

  For example, when a node leaves the cluster, only the processes that were running on that node
  will be redistributed. The rest of the processes will stay on the same node. When a new node
  joins the cluster, only some of the processes will be redistributed to the new node, and the
  rest will stay on the same node.

  > The hash ring implementation **does not guarantee** that all processes will always be
  > evenly distributed, but it does its best to distribute them as evenly as possible.

  This is the default distribution strategy.
  """

  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Ring
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey

  @type t() :: %__MODULE__{}
  defstruct []

  @spec handle_node_join(ProcessHub.hub_id(), node()) :: boolean()
  def handle_node_join(hub_id, node) do
    hash_ring = Ring.get_ring(hub_id) |> Ring.add_node(node)

    Storage.insert(hub_id, StorageKey.hr(), hash_ring)
  end

  @spec handle_node_leave(ProcessHub.hub_id(), node()) :: boolean()
  def handle_node_leave(hub_id, node) do
    hash_ring = Ring.get_ring(hub_id) |> Ring.remove_node(node)

    Storage.insert(hub_id, StorageKey.hr(), hash_ring)
  end

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.ConsistentHashing do
    @impl true
    @spec children_init(struct(), ProcessHub.hub_id(), [map()], keyword()) ::
            :ok | {:error, any()}
    def children_init(_strategy, _hub_id, _child_specs, _opts), do: :ok

    @impl true
    @spec belongs_to(
            ProcessHub.Strategy.Distribution.ConsistentHashing.t(),
            ProcessHub.hub_id(),
            ProcessHub.child_id(),
            pos_integer()
          ) :: [atom]
    def belongs_to(_strategy, hub_id, child_id, replication_factor) do
      Ring.get_ring(hub_id) |> Ring.key_to_nodes(child_id, replication_factor)
    end

    @impl true
    def init(_strategy, hub_id) do
      hub_nodes = Storage.get(hub_id, StorageKey.hn())

      Storage.insert(hub_id, StorageKey.hr(), Ring.create_ring(hub_nodes))

      join_handler = %HookManager{
        id: :ch_join,
        m: ProcessHub.Strategy.Distribution.ConsistentHashing,
        f: :handle_node_join,
        a: [hub_id, :_]
      }

      leave_handler = %HookManager{
        id: :ch_leave,
        m: ProcessHub.Strategy.Distribution.ConsistentHashing,
        f: :handle_node_leave,
        a: [hub_id, :_]
      }

      HookManager.register_handler(hub_id, Hook.pre_cluster_join(), join_handler)
      HookManager.register_handler(hub_id, Hook.pre_cluster_leave(), leave_handler)
    end

    @impl true
    @doc """
    Removes the local node from the hash ring.
    """
    def handle_shutdown(_strategy, hub_id) do
      hash_ring = Storage.get(hub_id, StorageKey.hr()) |> Ring.remove_node(node())

      Storage.insert(hub_id, StorageKey.hr(), hash_ring)
    end
  end
end
