defmodule ProcessHub.Strategy.Distribution.CentralizedScoreboard do
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
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Hub
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey

  @type t() :: %__MODULE__{}
  defstruct scoreboard: %{},
            query_node_fn: nil,
            arrange_scoreboard_fn: nil

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.CentralizedScoreboard do
    @impl true
    def init(_strategy, hub) do
      Application.ensure_started(:elector)
    end

    @impl true
    def belongs_to(_strategy, hub, child_id, replication_factor) do
      nodes = Cluster.get_nodes(hub.storage.misc, [:include_local])
      Cluster.key_to_node(nodes, child_id, replication_factor)
    end

    @impl true
    def children_init(_strategy, _hub, _child_specs, _opts), do: :ok
  end
end

# TODO: document that only one hub in the cluster should be able to use the centralized scoreboard strategy at the same time.
