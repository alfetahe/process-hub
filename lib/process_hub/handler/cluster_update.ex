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
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy

  defmodule NodeUp do
    @moduledoc """
    Handler for the node up event.
    """
    use Event

    @handle_node_sync_prio 1

    @type t() :: %__MODULE__{
            hub_id: ProcessHub.hub_id(),
            redun_strat: RedundancyStrategy.t(),
            sync_strat: SynchronizationStrategy.t(),
            migr_strat: MigrationStrategy.t(),
            partition_strat: PartitionToleranceStrategy.t(),
            dist_strat: DistributionStrategy.t(),
            new_node: node()
          }

    @enforce_keys [
      :hub_id,
      :redun_strat,
      :sync_strat,
      :migr_strat,
      :partition_strat,
      :dist_strat,
      :new_node
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = arg) do
      HookManager.dispatch_hook(
        arg.hub_id,
        Hook.pre_nodes_redistribution(),
        {:nodeup, arg.new_node}
      )

      distribute_processes(arg) |> Task.await_many(migration_timeout(arg.migr_strat))

      propagate_local_children(arg.hub_id, arg.new_node)

      HookManager.dispatch_hook(
        arg.hub_id,
        Hook.post_nodes_redistribution(),
        {:nodeup, arg.new_node}
      )

      State.unlock_local_event_handler(arg.hub_id)

      :ok
    end

    defp propagate_local_children(hub_id, new_node) do
      local_processes = Synchronizer.local_sync_data(hub_id)
      local_node = node()

      :erpc.cast(new_node, fn ->
        Dispatcher.propagate_event(
          hub_id,
          @event_sync_remote_children,
          {local_processes, local_node},
          :local,
          %{members: :local, priority: @handle_node_sync_prio}
        )
      end)
    end

    defp distribute_processes(arg) do
      repl_fact = RedundancyStrategy.replication_factor(arg.redun_strat)
      hub_nodes = Cluster.nodes(arg.hub_id, [:include_local])

      local_children(arg.hub_id)
      |> distributed_child_specs(
        arg.hub_id,
        arg.dist_strat,
        arg.new_node,
        hub_nodes,
        repl_fact,
        []
      )
      |> Enum.map(fn %{child_spec: child_spec, keep_local: keep_local, child_nodes: child_nodes} ->
        case keep_local do
          false ->
            Task.async(fn ->
              MigrationStrategy.handle_migration(
                arg.migr_strat,
                arg.hub_id,
                child_spec,
                arg.added_node,
                arg.sync_strat
              )
            end)

          true ->
            RedundancyStrategy.handle_post_update(
              arg.redun_strat,
              arg.hub_id,
              child_spec.id,
              child_nodes,
              {:up, arg.added_node}
            )

            # Will initiate the start of the child on the new node.
            Distributor.child_redist_init(arg.hub_id, child_spec, arg.new_node)

            Task.completed(:ok)
        end
      end)
    end

    defp local_children(hub_id) do
      local_node = node()

      ProcessRegistry.registry(hub_id)
      |> Enum.filter(fn {_child_id, {_child_spec, child_nodes}} ->
        Enum.member?(Keyword.keys(child_nodes), local_node)
      end)
    end

    defp distributed_child_specs(
           [],
           _hub_id,
           _dist_strat,
           _node,
           _hub_nodes,
           _replication_factor,
           acc
         ) do
      acc
    end

    defp distributed_child_specs(
           [{child_id, {child_spec, _child_nodes_old}} | childs],
           hub_id,
           dist_strat,
           node,
           hub_nodes,
           replication_factor,
           acc
         ) do
      child_nodes =
        DistributionStrategy.belongs_to(
          dist_strat,
          hub_id,
          child_id,
          hub_nodes,
          replication_factor
        )

      local_node = node()

      cond do
        Enum.member?(child_nodes, node) ->
          keep_local = Enum.member?(child_nodes, local_node)

          distributed_child_specs(
            childs,
            hub_id,
            dist_strat,
            node,
            hub_nodes,
            replication_factor,
            [
              %{child_spec: child_spec, keep_local: keep_local, child_nodes: child_nodes} | acc
            ]
          )

        true ->
          distributed_child_specs(
            childs,
            hub_id,
            dist_strat,
            node,
            hub_nodes,
            replication_factor,
            acc
          )
      end
    end

    defp migration_timeout(migr_strategy) do
      default_timeout = 5000

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
            redun_strategy: RedundancyStrategy.t(),
            dist_strat: DistributionStrategy.t(),
            hub_nodes: [node()]
          }

    @enforce_keys [
      :hub_id,
      :removed_node,
      :partition_strat,
      :redun_strategy,
      :dist_strat,
      :hub_nodes
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = args) do
      HookManager.dispatch_hook(
        args.hub_id,
        Hook.pre_nodes_redistribution(),
        {:nodedown, args.removed_node}
      )

      distribute_processes(args)

      State.unlock_local_event_handler(args.hub_id)

      hub_nodes = Cluster.nodes(args.hub_id, [:include_local])

      PartitionToleranceStrategy.handle_node_down(
        args.partition_strat,
        args.hub_id,
        args.removed_node,
        hub_nodes
      )

      HookManager.dispatch_hook(
        args.hub_id,
        Hook.post_nodes_redistribution(),
        {:nodedown, args.removed_node}
      )

      HookManager.dispatch_hook(args.hub_id, Hook.cluster_leave(), args)

      :ok
    end

    defp distribute_processes(%__MODULE__{} = arg) do
      children = ProcessRegistry.registry(arg.hub_id)
      repl_fact = RedundancyStrategy.replication_factor(arg.redun_strategy)

      removed_node_processes(
        children,
        arg.removed_node,
        arg.hub_id,
        arg.hub_nodes,
        arg.dist_strat,
        repl_fact
      )
      |> Enum.each(fn {child_id, child_spec, nodes_new, nodes_old} ->
        RedundancyStrategy.handle_post_update(
          arg.redun_strategy,
          arg.hub_id,
          child_id,
          nodes_new,
          {:down, arg.removed_node}
        )

        local_node = node()
        # Check if removed nodes procsses should be started on the local node.
        if !Enum.member?(nodes_old, local_node) && Enum.member?(nodes_new, local_node) do
          Distributor.child_redist_init(arg.hub_id, child_spec, local_node)
        end
      end)
    end

    defp removed_node_processes(children, removed_node, hub_id, hub_nodes, dist_strat, repl_fact) do
      Enum.reduce(children, [], fn {child_id, {child_spec, nodes_old}}, acc ->
        if Enum.member?(Keyword.keys(nodes_old), removed_node) do
          nodes_new =
            DistributionStrategy.belongs_to(dist_strat, hub_id, child_id, hub_nodes, repl_fact)

          [{child_id, child_spec, nodes_new, nodes_old} | acc]
        else
          acc
        end
      end)
    end
  end
end
