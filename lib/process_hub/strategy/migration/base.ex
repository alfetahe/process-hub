defprotocol ProcessHub.Strategy.Migration.Base do
  @moduledoc """
  The migration strategy protocol provides API functions for migrating child processes.
  """

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
          ProcessHub.hub_id(),
          [ProcessHub.child_spec()],
          node(),
          ProcessHub.Strategy.Synchronization.Base.t()
        ) :: :ok
  def handle_migration(struct, hub_id, child_specs, added_node, sync_strategy)
end
