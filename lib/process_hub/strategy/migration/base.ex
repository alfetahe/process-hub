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
  Migrates processes from the local to the remote node.

  Process migration happens when a new node joins the `ProcessHub` cluster, and some of the
  local processes are moved to the newly connected node. This also requires the processes
  to be terminated on the local node.

  The redundancy strategy will deal with scenarios where processes are not terminated locally
  and are duplicated on the new node.
  """
  @spec handle_migration(
          __MODULE__.t(),
          Hub.t(),
          [{ProcessHub.child_spec(), map()}],
          node(),
          ProcessHub.Strategy.Synchronization.Base.t()
        ) :: :ok
  def handle_migration(struct, hub, children_data, added_node, sync_strategy)

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
end
