defmodule ProcessHub.Handler.ClusterUpdate do
  @moduledoc false

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.Event
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.Synchronizer
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.State
  alias ProcessHub.Service.LocalStorage
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy

  defmodule NodeUp do
    @moduledoc """
    Handler for the node up event.
    """
    alias ProcessHub.Constant.PriorityLevel
    use Event

    @type t() :: %__MODULE__{
            hub_id: ProcessHub.hub_id(),
            redun_strat: RedundancyStrategy.t(),
            sync_strat: SynchronizationStrategy.t(),
            migr_strat: MigrationStrategy.t(),
            partition_strat: PartitionToleranceStrategy.t(),
            dist_strat: DistributionStrategy.t(),
            node: node(),
            repl_fact: pos_integer(),
            local_children: list(),
            keep: list(),
            migrate: list(),
            async_tasks: list()
          }

    @enforce_keys [
      :hub_id,
      :node
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
                  async_tasks: []
                ]

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = arg) do
      arg = add_strategies(arg)

      # Dispatch the nodes pre redistribution event.
      HookManager.dispatch_hook(arg.hub_id, Hook.pre_nodes_redistribution(), {:nodeup, arg.node})

      # Handle the redistribution of processes.
      distribute_processes(arg)

      # Propagate the local children to the new node.
      propagate_local_children(arg.hub_id, arg.node)

      # Dispatch the nodes post redistribution event.
      HookManager.dispatch_hook(arg.hub_id, Hook.post_nodes_redistribution(), {:nodeup, arg.node})

      # Unlock the event handler.
      State.unlock_event_handler(arg.hub_id)

      :ok
    end

    defp add_strategies(arg) do
      %__MODULE__{
        arg
        | sync_strat: LocalStorage.get(arg.hub_id, :synchronization_strategy),
          redun_strat: LocalStorage.get(arg.hub_id, :redundancy_strategy),
          dist_strat: LocalStorage.get(arg.hub_id, :distribution_strategy),
          migr_strat: LocalStorage.get(arg.hub_id, :migration_strategy),
          partition_strat: LocalStorage.get(arg.hub_id, :partition_tolerance_strategy)
      }
    end

    defp propagate_local_children(hub_id, node) do
      local_processes = Synchronizer.local_sync_data(hub_id)
      local_node = node()

      Dispatcher.propagate_event(
        hub_id,
        @event_sync_remote_children,
        {local_processes, local_node},
        %{members: [node], priority: PriorityLevel.locked()}
      )
    end

    defp distribute_processes(arg) do
      arg
      |> Map.put(:repl_fact, RedundancyStrategy.replication_factor(arg.redun_strat))
      |> local_children()
      |> dist_children()
      |> handle_migrate()
      |> handle_keep()
      |> wait_for_tasks()
    end

    defp wait_for_tasks(%__MODULE__{async_tasks: async_tasks, migr_strat: migr_strat} = _arg) do
      Task.await_many(async_tasks, migration_timeout(migr_strat))

      #  %__MODULE__{arg | async_tasks: []}

      :ok
    end

    defp handle_migrate(
           %__MODULE__{
             hub_id: hub_id,
             migrate: data,
             async_tasks: async_tasks,
             migr_strat: migr_strat,
             sync_strat: sync_strat,
             node: node
           } = arg
         ) do
      task =
        Task.async(fn ->
          child_specs =
            Enum.map(data, fn %{child_spec: child_spec} ->
              child_spec
            end)

          MigrationStrategy.handle_migration(migr_strat, hub_id, child_specs, node, sync_strat)
        end)

      %__MODULE__{arg | async_tasks: [task | async_tasks]}
    end

    defp handle_keep(
           %__MODULE__{
             hub_id: hub_id,
             keep: keep,
             redun_strat: redun_strat,
             async_tasks: async_tasks,
             node: node
           } = arg
         ) do
      task =
        Task.async(fn ->
          children_pids = ProcessRegistry.local_children(hub_id)

          child_specs =
            Enum.map(keep, fn %{child_spec: child_spec, child_nodes: child_nodes} ->
              RedundancyStrategy.handle_post_update(
                redun_strat,
                hub_id,
                child_spec.id,
                child_nodes,
                {:up, arg.node},
                pid: children_pids[child_spec.id]
              )

              child_spec
            end)

          Distributor.children_redist_init(hub_id, child_specs, node)
        end)

      %__MODULE__{arg | async_tasks: [task | async_tasks]}
    end

    defp local_children(%__MODULE__{hub_id: hub_id} = arg) do
      local_node = node()

      local_children =
        ProcessRegistry.registry(hub_id)
        |> Enum.filter(fn {_child_id, {_child_spec, child_nodes}} ->
          Enum.member?(Keyword.keys(child_nodes), local_node)
        end)

      %__MODULE__{arg | local_children: local_children}
    end

    defp dist_children(
           %__MODULE__{
             local_children: lc,
             dist_strat: dist_strat,
             hub_id: hub_id,
             repl_fact: rp,
             node: node
           } = arg
         ) do
      local_node = node()

      {keep, migrate} =
        Enum.reduce(lc, {[], []}, fn {child_id, {child_spec, _}}, {keep, migrate} = acc ->
          child_nodes = DistributionStrategy.belongs_to(dist_strat, hub_id, child_id, rp)

          case Enum.member?(child_nodes, node) do
            true ->
              case Enum.member?(child_nodes, local_node) do
                true ->
                  {[%{child_spec: child_spec, child_nodes: child_nodes} | keep], migrate}

                false ->
                  {keep, [%{child_spec: child_spec, child_nodes: child_nodes} | migrate]}
              end

            false ->
              acc
          end
        end)

      %__MODULE__{arg | keep: keep, migrate: migrate}
    end

    defp migration_timeout(migr_strategy) do
      default_timeout = 15000

      if Map.has_key?(migr_strategy, :retention) do
        case Map.get(migr_strategy, :retention, :none) do
          :none -> default_timeout
          timeout -> timeout + default_timeout
        end
      else
        default_timeout
      end
    end
  end

  defmodule NodeDown do
    @moduledoc """
    Handler for the node down event.
    """

    @type t() :: %__MODULE__{
            hub_id: ProcessHub.hub_id(),
            removed_node: node(),
            partition_strat: PartitionToleranceStrategy.t(),
            redun_strat: RedundancyStrategy.t(),
            dist_strat: DistributionStrategy.t(),
            hub_nodes: [node()]
          }

    @enforce_keys [
      :hub_id,
      :removed_node,
      :hub_nodes
    ]
    defstruct @enforce_keys ++ [:partition_strat, :redun_strat, :dist_strat]

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = arg) do
      arg = %__MODULE__{
        arg
        | partition_strat: LocalStorage.get(arg.hub_id, :partition_tolerance_strategy),
          redun_strat: LocalStorage.get(arg.hub_id, :redundancy_strategy),
          dist_strat: LocalStorage.get(arg.hub_id, :distribution_strategy)
      }

      HookManager.dispatch_hook(
        arg.hub_id,
        Hook.pre_nodes_redistribution(),
        {:nodedown, arg.removed_node}
      )

      distribute_processes(arg)

      State.unlock_event_handler(arg.hub_id)

      PartitionToleranceStrategy.handle_node_down(
        arg.partition_strat,
        arg.hub_id,
        arg.removed_node
      )

      HookManager.dispatch_hook(
        arg.hub_id,
        Hook.post_nodes_redistribution(),
        {:nodedown, arg.removed_node}
      )

      HookManager.dispatch_hook(arg.hub_id, Hook.post_cluster_leave(), arg)

      :ok
    end

    defp distribute_processes(%__MODULE__{} = arg) do
      children = ProcessRegistry.registry(arg.hub_id)

      removed_node_processes(children, arg.removed_node)
      |> Enum.each(fn {child_id, child_spec, nodes_new, nodes_old} ->
        RedundancyStrategy.handle_post_update(
          arg.redun_strat,
          arg.hub_id,
          child_id,
          nodes_new,
          {:down, arg.removed_node},
          []
        )

        local_node = node()
        # Check if removed nodes procsses should be started on the local node.
        if !Enum.member?(nodes_old, local_node) && Enum.member?(nodes_new, local_node) do
          # TODO: We should also pass all children not one by one.
          Distributor.children_redist_init(arg.hub_id, [child_spec], local_node)
        end
      end)
    end

    defp removed_node_processes(children, removed_node) do
      Enum.reduce(children, [], fn {child_id, {child_spec, nodes_old}}, acc ->
        if Enum.member?(Keyword.keys(nodes_old), removed_node) do
          nodes_new = Enum.filter(nodes_old, fn node -> node !== removed_node end)

          [{child_id, child_spec, nodes_new, nodes_old} | acc]
        else
          acc
        end
      end)
    end
  end
end
