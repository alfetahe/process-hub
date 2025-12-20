defmodule ProcessHub.Handler.ClusterUpdate do
  @moduledoc false

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.Event
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.Synchronizer
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.State
  alias ProcessHub.Service.Storage
  alias ProcessHub.Utility.Bag
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
    alias ProcessHub.Constant.PriorityLevel
    use Event

    @type t() :: %__MODULE__{
            redun_strat: RedundancyStrategy.t(),
            sync_strat: SynchronizationStrategy.t(),
            migr_strat: MigrationStrategy.t(),
            dist_strat: map(),
            nodes: [node()],
            hub: Hub.t()
          }

    @enforce_keys [
      :nodes,
      :hub
    ]
    defstruct @enforce_keys ++
                [
                  :redun_strat,
                  :migr_strat,
                  :sync_strat,
                  :dist_strat
                ]

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{hub: hub, nodes: nodes} = arg) do
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

      # Propagate the local children to the new nodes.
      propagate_local_children(hub, nodes)

      # Dispatch the nodes post redistribution event.
      HookManager.dispatch_hook(
        hub.storage.hook,
        Hook.post_nodes_redistribution(),
        {:nodeup, nodes}
      )

      # Unlock the event handler.
      State.unlock_event_handler(hub)

      :ok
    end

    defp distribute_processes(arg) do
      # Get registry data once
      registry_data = ProcessRegistry.dump(arg.hub.hub_id)
      replication_factor = RedundancyStrategy.replication_factor(arg.redun_strat)

      # Migration strategy handles migration (strategy decides how internally)
      MigrationStrategy.handle_migrate(
        arg.migr_strat,
        arg.hub,
        registry_data,
        arg.nodes,
        replication_factor,
        arg.sync_strat
      )

      # Redundancy strategy handles replication separately
      RedundancyStrategy.handle_redundancy(
        arg.redun_strat,
        arg.hub,
        registry_data,
        arg.nodes
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

    defp propagate_local_children(hub, nodes) do
      local_processes = Synchronizer.local_sync_data(hub)
      local_node = node()

      Dispatcher.propagate_event(
        hub.procs.event_queue,
        @event_sync_remote_children,
        {local_processes, local_node},
        %{members: nodes, priority: PriorityLevel.high()}
      )
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
            hub_nodes: [node()],
            hub: Hub.t(),
            rem_node_cids: [ProcessHub.child_id()]
          }

    @enforce_keys [
      :removed_nodes,
      :hub_nodes,
      :hub
    ]
    defstruct @enforce_keys ++ [:partition_strat, :redun_strat, :dist_strat, :rem_node_cids]

    @spec handle(t()) :: any()
    def handle(%__MODULE__{hub: hub} = arg) do
      %__MODULE__{
        arg
        | partition_strat: Storage.get(hub.storage.misc, StorageKey.strpart()),
          redun_strat: Storage.get(hub.storage.misc, StorageKey.strred()),
          dist_strat: Storage.get(hub.storage.misc, StorageKey.strdist())
      }
      |> dispatch_down_hooks()
      |> distribute_processes()
      |> clear_registry()
      |> handle_locking()
      |> dispatch_post_hooks()
    end

    defp dispatch_post_hooks(%__MODULE__{hub: %Hub{storage: %{hook: hook_storage}}} = arg) do
      Enum.each(arg.removed_nodes, fn node ->
        HookManager.dispatch_hook(
          hook_storage,
          Hook.post_nodes_redistribution(),
          {:nodedown, node}
        )

        HookManager.dispatch_hook(hook_storage, Hook.post_cluster_leave(), %{
          removed_node: node,
          hub: arg.hub
        })
      end)
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
        |> Map.new()

      if !Enum.empty?(children_nodes) do
        ProcessRegistry.bulk_delete(arg.hub.hub_id, children_nodes,
          hook_storage: arg.hub.storage.misc
        )
      end

      arg
    end

    defp distribute_processes(%__MODULE__{} = arg) do
      local_node = node()

      {redun, redist, cids} =
        removed_nodes_processes(arg)
        |> Enum.reduce({[], [], []}, fn {cid, cspec, m, nlist1, nlist2, rem_nodes},
                                        {redun, redist, cids} ->
          case Enum.member?(nlist1, local_node) do
            true ->
              # Already have locally - just update redundancy info
              {[{cid, nlist2, nlist1, []} | redun], redist, [{cid, rem_nodes} | cids]}

            false ->
              case Enum.member?(nlist2, local_node) do
                true ->
                  # Need to start locally
                  {redun, [{cspec, m} | redist], [{cid, rem_nodes} | cids]}

                false ->
                  # Not our concern
                  {redun, redist, [{cid, rem_nodes} | cids]}
              end
          end
        end)

      # Handle redundancy signals for processes that already exist locally
      if !Enum.empty?(redun) do
        handle_redundancy(arg, redun)
      end

      # Handle redistribution of processes that need to be started locally
      if !Enum.empty?(redist) do
        handle_redistribution(arg.hub, redist)
      end

      Map.put(arg, :rem_node_cids, cids)
    end

    defp handle_redistribution(hub, children_data) do
      Distributor.children_redist_init(hub, node(), children_data)
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

    # Find all children affected by any of the removed nodes
    defp removed_nodes_processes(arg) do
      repl_fact = RedundancyStrategy.replication_factor(arg.redun_strat)
      reg_dump = ProcessRegistry.dump(arg.hub.hub_id)
      cids = Enum.map(reg_dump, fn {cid, _} -> cid end)
      local_node = node()

      cid_pid_node_pairs =
        DistributionStrategy.belongs_to(arg.dist_strat, arg.hub, cids, repl_fact)

      Enum.reduce(reg_dump, [], fn {child_id, {child_spec, node_pids, metadata}}, acc ->
        nodes_orig = Keyword.keys(node_pids)
        nodes_updated = Bag.get_by_key(cid_pid_node_pairs, child_id, [])

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
