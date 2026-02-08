defmodule ProcessHub.Task.ClusterUpdateTask do
  @moduledoc false

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.Event
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.State
  alias ProcessHub.Service.Storage
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Hub

  defmodule NodeUp do
    @moduledoc """
    Handler for the node up event.
    """
    use Event

    @type t() :: %__MODULE__{
            redun_strat: RedundancyStrategy.t(),
            sync_strat: SynchronizationStrategy.t(),
            migr_strat: MigrationStrategy.t(),
            dist_strat: map(),
            joined_nodes: [node()],
            calculated_cids: %{ProcessHub.child_id() => [node()]},
            hub: Hub.t()
          }

    @enforce_keys [
      :joined_nodes,
      :hub
    ]
    defstruct @enforce_keys ++
                [
                  :redun_strat,
                  :migr_strat,
                  :sync_strat,
                  :dist_strat,
                  calculated_cids: %{}
                ]

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{hub: hub, joined_nodes: nodes} = arg) do
      if !State.is_partitioned?(hub) do
        arg = attach_data(arg)

        # Dispatch the nodes pre redistribution event.
        HookManager.dispatch_hook(
          hub.storage.hook,
          Hook.pre_nodes_redistribution(),
          {:nodeup, nodes}
        )

        # Handle the redistribution of processes.
        if Map.get(arg.dist_strat, :nodeup_redistribution, true) do
          distribute_processes(arg)
        end
      end

      # Dispatch the nodes post redistribution event.
      dispatch_post_hooks(arg)

      :ok
    end

    defp dispatch_post_hooks(%__MODULE__{
           joined_nodes: nodes,
           hub: %Hub{storage: %{hook: hook_storage}}
         }) do
      Enum.each(nodes, fn node ->
        HookManager.dispatch_hook(hook_storage, Hook.post_cluster_join(), %{
          joined_node: node
        })
      end)

      HookManager.dispatch_hook(
        hook_storage,
        Hook.post_nodes_redistribution(),
        %{joined_node: nodes}
      )
    end

    defp distribute_processes(arg) do
      # Migration strategy handles PRIMARY process migration.
      arg =
        MigrationStrategy.handle_topology_expansion(
          arg.migr_strat,
          arg.hub,
          arg.joined_nodes,
          arg
        )

      # Redundancy strategy handles REPLICAS (indices 1+) + mode signals.
      # Pass calculated_cids from migration strategy.
      RedundancyStrategy.handle_redundancy(
        arg.redun_strat,
        arg.hub,
        arg.calculated_cids,
        arg.joined_nodes
      )

      :ok
    end

    defp attach_data(%__MODULE__{} = arg) do
      %__MODULE__{
        arg
        | sync_strat: Storage.get(arg.hub.storage.misc, StorageKey.strsyn()),
          redun_strat: Storage.get(arg.hub.storage.misc, StorageKey.strred()),
          dist_strat: Storage.get(arg.hub.storage.misc, StorageKey.strdist()),
          migr_strat: Storage.get(arg.hub.storage.misc, StorageKey.strmigr())
      }
    end
  end

  defmodule NodeDown do
    @moduledoc """
    Handler for node down events.
    Processes one or more node failures together to avoid duplicate redistributions.
    Always operates on a list of removed nodes (even if single).
    """

    @type t() :: %__MODULE__{
            removed_nodes: [node()],
            partition_strat: PartitionToleranceStrategy.t(),
            redun_strat: RedundancyStrategy.t(),
            dist_strat: DistributionStrategy.t(),
            migr_strat: MigrationStrategy.t(),
            hub_nodes: [node()],
            hub: Hub.t(),
            rem_node_cids: [ProcessHub.child_id()],
            calculated_cids: %{ProcessHub.child_id() => [node()]}
          }

    @enforce_keys [
      :removed_nodes,
      :hub_nodes,
      :hub
    ]
    defstruct @enforce_keys ++
                [
                  :partition_strat,
                  :redun_strat,
                  :dist_strat,
                  :migr_strat,
                  :rem_node_cids,
                  calculated_cids: %{}
                ]

    @spec handle(t()) :: any()
    def handle(%__MODULE__{hub: hub} = arg) do
      %__MODULE__{
        arg
        | partition_strat: Storage.get(hub.storage.misc, StorageKey.strpart()),
          redun_strat: Storage.get(hub.storage.misc, StorageKey.strred()),
          dist_strat: Storage.get(hub.storage.misc, StorageKey.strdist()),
          migr_strat: Storage.get(hub.storage.misc, StorageKey.strmigr())
      }
      |> dispatch_down_hooks()
      |> distribute_processes()
      |> clear_registry()
      |> handle_locking()
      |> dispatch_post_hooks()
    end

    defp dispatch_post_hooks(%__MODULE__{hub: %Hub{storage: %{hook: hook_storage}}} = arg) do
      Enum.each(arg.removed_nodes, fn node ->
        HookManager.dispatch_hook(hook_storage, Hook.post_cluster_leave(), %{
          removed_node: node
        })
      end)

      HookManager.dispatch_hook(
        hook_storage,
        Hook.post_nodes_redistribution(),
        %{removed_nodes: arg.removed_nodes}
      )
    end

    defp handle_locking(arg) do
      # Check partition tolerance for all removed nodes
      # If any requires staying locked, stay locked
      any_lock =
        Enum.any?(arg.removed_nodes, fn node ->
          PartitionToleranceStrategy.toggle_lock?(
            arg.partition_strat,
            arg.hub,
            node
          )
        end)

      if any_lock do
        State.toggle_quorum_failure(arg.hub)
      else
        State.unlock_event_handler(arg.hub)
      end

      arg
    end

    defp dispatch_down_hooks(arg) do
      Enum.each(arg.removed_nodes, fn node ->
        HookManager.dispatch_hook(
          arg.hub.storage.hook,
          Hook.pre_nodes_redistribution(),
          {:nodedown, node}
        )
      end)

      arg
    end

    # Removes all processes from the registry that were running on removed nodes.
    defp clear_registry(arg) do
      children_nodes =
        Enum.flat_map(arg.rem_node_cids, fn {child_id, nodes} ->
          [{child_id, nodes}]
        end)

      if !Enum.empty?(children_nodes) do
        ProcessRegistry.bulk_delete(arg.hub.hub_id, children_nodes,
          hook_storage: arg.hub.storage.misc
        )
      end

      arg
    end

    defp distribute_processes(%__MODULE__{} = arg) do
      # Get registry data once and calculate belongs_to for all cids upfront.
      # This avoids expensive repeated hash ring calculations.
      repl_fact = RedundancyStrategy.replication_factor(arg.redun_strat)
      registry_data = ProcessRegistry.dump(arg.hub.hub_id)
      cids = Enum.map(registry_data, fn {cid, _} -> cid end)

      cid_node_map =
        if cids != [] do
          DistributionStrategy.belongs_to(arg.dist_strat, arg.hub, cids, repl_fact)
        else
          %{}
        end

      # Store calculated cids in arg for reuse by migration strategies.
      arg = %__MODULE__{arg | calculated_cids: cid_node_map}

      # Get affected children for registry cleanup and redundancy updates
      affected = removed_nodes_processes(arg, registry_data)
      rem_cids = Enum.map(affected, fn {cid, _, _, _, _, rem} -> {cid, rem} end)

      # Build redundancy list from ALL local children (ring changes affect any child)
      redun = build_redundancy_list(arg)

      if !Enum.empty?(redun), do: handle_redundancy(arg, redun)

      # Migration handles PRIMARY placement only
      arg =
        MigrationStrategy.handle_topology_contraction(
          arg.migr_strat,
          arg.hub,
          arg.removed_nodes,
          arg
        )

      # Redundancy handles REPLICA starting after contraction
      RedundancyStrategy.handle_redundancy(
        arg.redun_strat,
        arg.hub,
        arg.calculated_cids,
        arg.removed_nodes
      )

      Map.put(arg, :rem_node_cids, rem_cids)
    end

    defp build_redundancy_list(arg) do
      local_children = ProcessRegistry.local_children(arg.hub.hub_id)

      # Use pre-calculated cid_node_map from arg to avoid recalculating hash ring.
      Enum.map(local_children, fn {cid, {_, node_pids, _}} ->
        {cid, Map.get(arg.calculated_cids, cid, []), Keyword.keys(node_pids), []}
      end)
    end

    defp handle_redundancy(arg, children) do
      # Dispatch hook with first removed node for compatibility
      first_node = List.first(arg.removed_nodes)

      HookManager.dispatch_hook(
        arg.hub.storage.hook,
        Hook.pre_children_redistribution(),
        {children, {:down, first_node}}
      )
    end

    # Find all children affected by any of the removed nodes.
    # Uses pre-calculated cid_node_map from arg to avoid recalculating hash ring.
    defp removed_nodes_processes(arg, registry_data) do
      local_node = node()

      Enum.reduce(registry_data, [], fn {child_id, {child_spec, node_pids, metadata}}, acc ->
        nodes_orig = Keyword.keys(node_pids)
        nodes_updated = Map.get(arg.calculated_cids, child_id, [])

        # Find which removed nodes had this child
        affected_removed_nodes =
          Enum.filter(arg.removed_nodes, fn rem_node ->
            Enum.member?(nodes_orig, rem_node)
          end)

        # Include child if:
        # 1. Any removed node had the child, OR
        # 2. Local should have it but doesn't
        should_include =
          length(affected_removed_nodes) > 0 or
            (Enum.member?(nodes_updated, local_node) and
               not Enum.member?(nodes_orig, local_node))

        if should_include do
          rem_nodes =
            if length(affected_removed_nodes) > 0,
              do: affected_removed_nodes,
              else: arg.removed_nodes

          [{child_id, child_spec, metadata, nodes_orig, nodes_updated, rem_nodes} | acc]
        else
          acc
        end
      end)
    end
  end
end
