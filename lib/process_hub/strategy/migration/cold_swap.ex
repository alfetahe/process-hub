defmodule ProcessHub.Strategy.Migration.ColdSwap do
  @moduledoc """
  The cold swap migration strategy implements the `ProcessHub.Strategy.Migration.Base` protocol.
  It provides a migration strategy where the local process is terminated before starting it on
  the remote node.

  Cold swap is a safe strategy if we want to ensure that the child process is not
  running on multiple nodes at the same time.

  This is the default strategy for process migration.
  """

  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.Storage
  alias ProcessHub.Utility.Bag
  alias ProcessHub.DistributedSupervisor

  @typedoc """
  The cold swap migration struct.

  This struct does not contain any configuration options.
  """
  @type t() :: %__MODULE__{}
  defstruct []

  defimpl MigrationStrategy, for: ProcessHub.Strategy.Migration.ColdSwap do
    @impl true
    def init(strategy, _hub), do: strategy

    # TODO: refactor with below.
    @impl true
    def handle_migration(_struct, _hub, _children_data, _added_node, _sync_strategy) do
      # ColdSwap uses handle_migrate instead - each node handles its own locally
      :ok
    end

    @impl true
    def handle_migrate(
          _struct,
          hub,
          registry_data,
          nodes,
          replication_factor,
          sync_strategy
        ) do
      local_node = node()
      dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())

      # Calculate new distribution for all children
      cids = Enum.map(registry_data, fn {cid, _} -> cid end)

      cid_node_pairs =
        if length(cids) > 0 do
          DistributionStrategy.belongs_to(dist_strat, hub, cids, replication_factor)
        else
          []
        end

      # Get currently running local children
      local_pids = DistributedSupervisor.local_children(hub.procs.dist_sup)
      local_child_ids = Map.keys(local_pids)

      # Categorize each child
      {to_start, to_stop} =
        Enum.reduce(registry_data, {[], []}, fn {child_id, {cs, _node_pids, m}}, {start, stop} ->
          nodes_new = Bag.get_by_key(cid_node_pairs, child_id, [])

          running_locally = Enum.member?(local_child_ids, child_id)
          should_be_local = Enum.member?(nodes_new, local_node)

          cond do
            # Running locally but shouldn't be anymore - stop it
            running_locally and not should_be_local ->
              {start, [{cs, m} | stop]}

            # Should be local but not running - start it
            should_be_local and not running_locally ->
              {[{cs, m} | start], stop}

            # No change needed
            true ->
              {start, stop}
          end
        end)

      # Execute locally - no cross-node calls
      if length(to_stop) > 0 do
        child_ids = Enum.map(to_stop, fn {cs, _m} -> cs.id end)
        Distributor.children_terminate(hub, child_ids, sync_strategy)
      end

      if length(to_start) > 0 do
        Distributor.children_redist_init(hub, local_node, to_start)
      end

      # Dispatch migration hook
      migrated = to_stop ++ to_start

      if length(migrated) > 0 do
        HookManager.dispatch_hook(
          hub.storage.hook,
          Hook.children_migrated(),
          {nodes, migrated}
        )
      end

      :ok
    end
  end
end
