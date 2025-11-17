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
            partition_strat: PartitionToleranceStrategy.t(),
            dist_strat: DistributionStrategy.t(),
            node: node(),
            hub: Hub.t(),
            repl_fact: pos_integer(),
            local_children: list(),
            keep: list(),
            migrate: list(),
            migr_base_timeout: pos_integer(),
            async_tasks: list(),
            operation_id: reference(),
            migration_count: non_neg_integer()
          }

    @enforce_keys [
      :node,
      :hub
    ]
    defstruct @enforce_keys ++
                [
                  :repl_fact,
                  :local_children,
                  :keep,
                  :migrate,
                  :redun_strat,
                  :migr_strat,
                  :sync_strat,
                  :partition_strat,
                  :dist_strat,
                  :migr_base_timeout,
                  :operation_id,
                  :migration_count,
                  async_tasks: []
                ]

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{hub: hub, node: node} = arg) do
      arg = attach_data(arg)

      # Generate unique operation ID for tracking migration completions
      operation_id = make_ref()

      # Dispatch the nodes pre redistribution event.
      HookManager.dispatch_hook(
        hub.storage.hook,
        Hook.pre_nodes_redistribution(),
        {:nodeup, node}
      )

      # Handle the redistribution of processes.
      expected_completions =
        if Map.get(arg.dist_strat, :nodeup_redistribution, true) do
          distribute_processes(arg, operation_id)
        else
          0
        end

      # Propagate the local children to the new node.
      propagate_local_children(hub, node)

      # Wait for all migration completions before firing hook
      wait_for_migration_completions(expected_completions, operation_id, arg)

      # Dispatch the nodes post redistribution event.
      HookManager.dispatch_hook(
        hub.storage.hook,
        Hook.post_nodes_redistribution(),
        {:nodeup, node}
      )

      # Unlock the event handler.
      State.unlock_event_handler(hub)

      :ok
    end

    defp distribute_processes(arg, operation_id) do
      result =
        arg
        |> Map.put(:repl_fact, RedundancyStrategy.replication_factor(arg.redun_strat))
        |> Map.put(:operation_id, operation_id)
        |> Map.put(:migration_count, 0)
        |> local_children()
        |> dist_children()
        |> handle_migrate()
        |> handle_keep()
        |> wait_for_tasks()

      # Return the count of expected migration completions
      result.migration_count
    end

    defp attach_data(arg) do
      %__MODULE__{
        arg
        | sync_strat: Storage.get(arg.hub.storage.misc, StorageKey.strsyn()),
          redun_strat: Storage.get(arg.hub.storage.misc, StorageKey.strred()),
          dist_strat: Storage.get(arg.hub.storage.misc, StorageKey.strdist()),
          migr_strat: Storage.get(arg.hub.storage.misc, StorageKey.strmigr()),
          partition_strat: Storage.get(arg.hub.storage.misc, StorageKey.strpart()),
          migr_base_timeout: Storage.get(arg.hub.storage.misc, StorageKey.mbt())
      }
    end

    defp propagate_local_children(hub, node) do
      local_processes = Synchronizer.local_sync_data(hub)
      local_node = node()

      Dispatcher.propagate_event(
        hub.procs.event_queue,
        @event_sync_remote_children,
        {local_processes, local_node},
        %{members: [node], priority: PriorityLevel.locked()}
      )
    end

    defp wait_for_tasks(
           %__MODULE__{
             async_tasks: async_tasks,
             migr_strat: migr_strat,
             migr_base_timeout: migr_base_timeout
           } = arg
         ) do
      Task.await_many(async_tasks, migration_timeout(migr_strat, migr_base_timeout))

      arg
    end

    defp wait_for_migration_completions(0, _operation_id, _arg), do: :ok

    defp wait_for_migration_completions(expected_count, operation_id, arg) do
      timeout = migration_timeout(arg.migr_strat, arg.migr_base_timeout)

      wait_for_completions_loop(expected_count, operation_id, timeout)
    end

    defp wait_for_completions_loop(0, _operation_id, _timeout), do: :ok

    defp wait_for_completions_loop(remaining, operation_id, timeout) do
      receive do
        {:migration_complete, ^operation_id} ->
          wait_for_completions_loop(remaining - 1, operation_id, timeout)
      after
        timeout ->
          :ok
      end
    end

    defp handle_migrate(
           %__MODULE__{
             migrate: data,
             async_tasks: async_tasks,
             migr_strat: migr_strat,
             sync_strat: sync_strat,
             node: node,
             operation_id: operation_id,
             migration_count: migration_count
           } = arg
         ) do
      # Calculate how many migrations will be sent (one per batch to this node)
      new_migration_count =
        if !Enum.empty?(data) do
          migration_count + 1
        else
          migration_count
        end

      # Capture self() before async task
      handler_pid = self()

      task =
        Task.async(fn ->
          child_data =
            Enum.map(data, fn %{child_spec: cs, metadata: m} ->
              {cs, m}
            end)

          if !Enum.empty?(child_data) do
            # Store migration options in hub storage for Distributor to use
            opts = [operation_id: operation_id, migration_reply_to: handler_pid]
            Storage.insert(arg.hub.storage.misc, :migration_opts, opts)

            MigrationStrategy.handle_migration(
              migr_strat,
              arg.hub,
              child_data,
              node,
              sync_strat
            )
          end
        end)

      %__MODULE__{arg | async_tasks: [task | async_tasks], migration_count: new_migration_count}
    end

    defp handle_keep(
           %__MODULE__{
             hub: hub,
             keep: keep,
             async_tasks: async_tasks,
             node: node,
             operation_id: operation_id,
             migration_count: migration_count
           } = arg
         ) do
      # Calculate how many migrations will be sent (one per batch to this node)
      new_migration_count =
        if !Enum.empty?(keep) do
          migration_count + 1
        else
          migration_count
        end

      # Capture self() before async task since self() inside task would be task's PID
      handler_pid = self()

      task =
        Task.async(fn ->
          if !Enum.empty?(keep) do
            handle_redundancy(hub, node, keep)
            handle_redistribution(hub, node, keep, operation_id, handler_pid)
          end
        end)

      %__MODULE__{arg | async_tasks: [task | async_tasks], migration_count: new_migration_count}
    end

    defp handle_redistribution(hub, node, children, operation_id, reply_to) do
      redist_children =
        Enum.map(children, fn %{child_spec: cs, child_nodes: cn, metadata: m} ->
          %{
            hub_id: hub.hub_id,
            nodes: cn,
            child_id: cs.id,
            child_spec: cs,
            metadata: m,
            migration_add: true
          }
        end)

      Dispatcher.children_migrate(hub.procs.event_queue, [{node, redist_children}],
        migration_add: true,
        operation_id: operation_id,
        migration_reply_to: reply_to
      )
    end

    defp handle_redundancy(hub, node, children) do
      children_pids = ProcessRegistry.local_data(hub.hub_id)
      |> Enum.map(fn {k, {_cs, cn, _meta}} ->
        {k, Keyword.get(cn, node())}
      end)

      redun_data =
        Enum.map(children, fn %{child_spec: cs, child_nodes: cn} ->
          local_pid = (Enum.find(children_pids, fn {k, _v} -> k === cs.id end) || {nil, nil}) |> elem(1)

          {cs.id, cn, [pid: local_pid]}
        end)

      HookManager.dispatch_hook(
        hub.storage.hook,
        Hook.pre_children_redistribution(),
        {redun_data, {:up, node}}
      )
    end

    defp local_children(%__MODULE__{hub: hub} = arg) do
      local_node = node()

      local_children =
        ProcessRegistry.dump(hub.hub_id)
        |> Enum.filter(fn {_child_id, {_child_spec, child_nodes, _metadata}} ->
          Enum.member?(Keyword.keys(child_nodes), local_node)
        end)

      %__MODULE__{arg | local_children: local_children}
    end

    defp dist_children(
           %__MODULE__{
             local_children: lc,
             dist_strat: dist_strat,
             repl_fact: rp,
             node: node
           } = arg
         ) do
      local_node = node()
      cids = Enum.map(lc, fn {child_id, _} -> child_id end)

      cid_pid_node_pairs =
        if length(cids) > 0 do
          DistributionStrategy.belongs_to(dist_strat, arg.hub, cids, rp)
        else
          []
        end

      {keep, migrate} =
        Enum.reduce(lc, {[], []}, fn {child_id, {cs, _, m}}, {keep, migrate} = acc ->
          cn = Bag.get_by_key(cid_pid_node_pairs, child_id, [])

          case Enum.member?(cn, node) do
            true ->
              case Enum.member?(cn, local_node) do
                true ->
                  {[%{child_spec: cs, child_nodes: cn, metadata: m} | keep], migrate}

                false ->
                  {keep, [%{child_spec: cs, child_nodes: cn, metadata: m} | migrate]}
              end

            false ->
              acc
          end
        end)

      %__MODULE__{arg | keep: keep, migrate: migrate}
    end

    defp migration_timeout(migr_strategy, migr_base_timeout) do
      if Map.has_key?(migr_strategy, :retention) do
        case Map.get(migr_strategy, :retention, :none) do
          :none -> migr_base_timeout
          timeout -> timeout + migr_base_timeout
        end
      else
        migr_base_timeout
      end
    end
  end

  defmodule NodeDown do
    @moduledoc """
    Handler for the node down event.
    """

    @type t() :: %__MODULE__{
            removed_node: node(),
            partition_strat: PartitionToleranceStrategy.t(),
            redun_strat: RedundancyStrategy.t(),
            dist_strat: DistributionStrategy.t(),
            hub_nodes: [node()],
            hub: Hub.t(),
            rem_node_cids: [ProcessHub.child_id()]
          }

    @enforce_keys [
      :removed_node,
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
      |> dispatch_down_hook()
      |> distribute_processes()
      |> clear_registry()
      |> handle_locking()
      |> dispatch_post_hooks()
    end

    defp dispatch_post_hooks(%__MODULE__{hub: %Hub{storage: %{hook: hook_storage}}} = arg) do
      HookManager.dispatch_hook(
        hook_storage,
        Hook.post_nodes_redistribution(),
        {:nodedown, arg.removed_node}
      )

      HookManager.dispatch_hook(hook_storage, Hook.post_cluster_leave(), arg)
    end

    defp handle_locking(arg) do
      lock_status =
        PartitionToleranceStrategy.toggle_lock?(
          arg.partition_strat,
          arg.hub,
          arg.removed_node
        )

      if lock_status do
        State.toggle_quorum_failure(arg.hub)
      else
        State.unlock_event_handler(arg.hub)
      end

      arg
    end

    defp dispatch_down_hook(arg) do
      HookManager.dispatch_hook(
        arg.hub.storage.hook,
        Hook.pre_nodes_redistribution(),
        {:nodedown, arg.removed_node}
      )

      arg
    end

    # Removes all processes from the registry that were running on the removed node.
    defp clear_registry(arg) do
      children_nodes =
        Enum.map(arg.rem_node_cids, fn child_id ->
          {child_id, [arg.removed_node]}
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
        removed_node_processes(arg)
        |> Enum.reduce({[], [], []}, fn {cid, cspec, m, nlist1, nlist2}, {redun, redist, cids} ->
          case Enum.member?(nlist1, local_node) do
            true ->
              {[{cid, nlist2, []} | redun], redist, [cid | cids]}

            false ->
              case Enum.member?(nlist2, local_node) do
                true ->
                  {redun, [{cspec, m} | redist], [cid | cids]}

                false ->
                  {redun, redist, [cid | cids]}
              end
          end
        end)

      handle_redundancy(arg, redun)

      if !Enum.empty?(redist) do
        handle_redistribution(arg.hub, redist)
      end

      Map.put(arg, :rem_node_cids, cids)
    end

    defp handle_redistribution(hub, children_data) do
      # Local node is part of the new nodes and therefore we need to start
      # the child process locally.
      Distributor.children_redist_init(hub, node(), children_data)
    end

    defp handle_redundancy(arg, children) do
      HookManager.dispatch_hook(
        arg.hub.storage.hook,
        Hook.pre_children_redistribution(),
        {children, {:down, arg.removed_node}}
      )
    end

    defp removed_node_processes(arg) do
      repl_fact = RedundancyStrategy.replication_factor(arg.redun_strat)
      reg_dump = ProcessRegistry.dump(arg.hub.hub_id)
      cids = Enum.map(reg_dump, fn {cid, _} -> cid end)

      cid_pid_node_pairs =
        DistributionStrategy.belongs_to(arg.dist_strat, arg.hub, cids, repl_fact)

      Enum.reduce(reg_dump, [], fn {child_id, {child_spec, node_pids, metadata}}, acc ->
        nodes_orig = Keyword.keys(node_pids)

        if Enum.member?(nodes_orig, arg.removed_node) do
          nodes_updated = Bag.get_by_key(cid_pid_node_pairs, child_id, [])
          [{child_id, child_spec, metadata, nodes_orig, nodes_updated} | acc]
        else
          acc
        end
      end)
    end
  end
end
