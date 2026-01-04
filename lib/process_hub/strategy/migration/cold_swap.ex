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

    @impl true
    def handle_migrate(
          _struct,
          hub,
          registry_data,
          nodes,
          replication_factor,
          _sync_strategy
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

      # Categorize each child based on whether it should migrate to new nodes
      {to_stop_locally, to_send_to_nodes, migrated} =
        Enum.reduce(registry_data, {[], %{}, []}, fn {child_id, {cs, node_pids, m}},
                                                      {stop_acc, send_acc, migrated_acc} ->
          nodes_new = Bag.get_by_key(cid_node_pairs, child_id, [])
          running_locally = Enum.member?(local_child_ids, child_id)
          is_orphaned = Keyword.keys(node_pids) == []

          # Find which new node(s) this child should be assigned to
          # (intersection of belongs_to result and newly joined nodes)
          target_new_nodes = Enum.filter(nodes, fn n -> Enum.member?(nodes_new, n) end)

          cond do
            # Case 1: Running locally, should move to new node, should NOT stay local
            running_locally and length(target_new_nodes) > 0 and
                not Enum.member?(nodes_new, local_node) ->
              target_node = List.first(target_new_nodes)

              updated_send =
                Map.update(send_acc, target_node, [{cs, m}], fn list -> [{cs, m} | list] end)

              {[{cs, m} | stop_acc], updated_send, [{cs, m} | migrated_acc]}

            # Case 2: Orphaned (not running anywhere) and should be on new node
            is_orphaned and length(target_new_nodes) > 0 ->
              target_node = List.first(target_new_nodes)

              updated_send =
                Map.update(send_acc, target_node, [{cs, m}], fn list -> [{cs, m} | list] end)

              {stop_acc, updated_send, [{cs, m} | migrated_acc]}

            # Case 3: No action needed
            true ->
              {stop_acc, send_acc, migrated_acc}
          end
        end)

      # Execute: Stop children locally (fire and forget)
      if length(to_stop_locally) > 0 do
        Enum.each(to_stop_locally, fn {cs, _m} ->
          DistributedSupervisor.terminate_child(hub.procs.dist_sup, cs.id)
        end)
      end

      # Execute: Send start requests to new nodes (fire and forget)
      Enum.each(to_send_to_nodes, fn {target_node, children_data} ->
        if length(children_data) > 0 do
          Distributor.children_redist_init(hub, target_node, children_data)
        end
      end)

      # Dispatch migration hook
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
