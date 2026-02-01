defprotocol ProcessHub.Strategy.Migration.Base do
  alias ProcessHub.Hub

  @moduledoc """
  The migration strategy protocol provides API functions for migrating child processes.
  """

  @doc """
  Triggered when coordinator is initialized.

  Could be used to perform initialization.
  """
  @spec init(struct(), Hub.t()) :: struct()
  def init(strategy, hub)

  @doc """
  Handles migration when nodes join the cluster.

  The strategy receives the full registry data and decides internally
  what actions to take (terminate, start, migrate to remote, etc).
  Each strategy implementation handles its own logic without the caller
  needing to know implementation details.

  ## Parameters
  - `struct` - the strategy struct
  - `hub` - the hub state
  - `registry_data` - full dump from ProcessRegistry.dump()
  - `nodes` - list of nodes that triggered redistribution
  - `replication_factor` - from redundancy strategy
  - `sync_strategy` - synchronization strategy for propagating changes
  """
  @spec handle_migrate(
          __MODULE__.t(),
          Hub.t(),
          registry_data :: list(),
          nodes :: [node()],
          replication_factor :: pos_integer(),
          ProcessHub.Strategy.Synchronization.Base.t()
        ) :: :ok
  def handle_migrate(struct, hub, registry_data, nodes, replication_factor, sync_strategy)

  @spec handle_topology_expansion(
          struct :: __MODULE__.t(),
          hub :: Hub.t(),
          nodes :: [node()],
          handler :: ProcessHub.Task.ClusterUpdateTask.NodeUp.t()
        ) :: ProcessHub.Task.ClusterUpdateTask.NodeUp.t()
  def handle_topology_expansion(struct, hub, nodes, handler)

  @doc """
  Handles migration when nodes leave the cluster (topology contraction).

  Called from NodeDown handler to redistribute processes from removed nodes.
  Each strategy implementation handles its own logic for starting processes
  that should now be on the local node.

  ## Parameters
  - `struct` - the strategy struct
  - `hub` - the hub state
  - `removed_nodes` - list of nodes that have left the cluster
  - `handler` - the NodeDown handler struct

  ## Returns
  Updated handler struct with any additional data computed during processing.
  """
  @spec handle_topology_contraction(
          struct :: __MODULE__.t(),
          hub :: Hub.t(),
          removed_nodes :: [node()],
          handler :: ProcessHub.Task.ClusterUpdateTask.NodeDown.t()
        ) :: ProcessHub.Task.ClusterUpdateTask.NodeDown.t()
  def handle_topology_contraction(struct, hub, removed_nodes, handler)
end
