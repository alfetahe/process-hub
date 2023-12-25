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
            node: node(),
            repl_fact: pos_integer(),
            local_children: list()
          }

    @enforce_keys [
      :hub_id,
      :redun_strat,
      :sync_strat,
      :migr_strat,
      :partition_strat,
      :dist_strat,
      :node
    ]
    defstruct @enforce_keys ++ [:repl_fact, :local_children]

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = arg) do
      # Dispatch the nodes pre redistribution event.
      HookManager.dispatch_hook(arg.hub_id, Hook.pre_nodes_redistribution(), {:nodeup, arg.node})

      # Handle the redistribution of processes.
      distribute_processes(arg) |> Task.await_many(migration_timeout(arg.migr_strat))

      # Propagate the local children to the new node.
      propagate_local_children(arg.hub_id, arg.node)

      # Dispatch the nodes post redistribution event.
      HookManager.dispatch_hook(arg.hub_id, Hook.post_nodes_redistribution(), {:nodeup, arg.node})

      # Unlock the local event handler.
      State.unlock_local_event_handler(arg.hub_id)

      :ok
    end

    defp propagate_local_children(hub_id, node) do
      local_processes = Synchronizer.local_sync_data(hub_id)
      local_node = node()

      :erpc.cast(node, fn ->
        Dispatcher.propagate_event(
          hub_id,
          @event_sync_remote_children,
          {local_processes, local_node},
          :local,
          %{members: :local, priority: @handle_node_sync_prio}
        )
      end)
    end

    defp distribute_processes(
           %__MODULE__{
             node: node,
             hub_id: hub_id,
             redun_strat: redun_strat,
             migr_strat: migr_strat,
             sync_strat: sync_strat
           } = arg
         ) do
      arg
      |> Map.put(:repl_fact, RedundancyStrategy.replication_factor(arg.redun_strat))
      |> local_children()
      |> distributed_child_specs([])
      |> Enum.map(fn %{child_spec: child_spec, keep_local: keep_local, child_nodes: child_nodes} ->
        case keep_local do
          false ->
            Task.async(fn ->
              MigrationStrategy.handle_migration(migr_strat, hub_id, child_spec, node, sync_strat)
            end)

          true ->
            RedundancyStrategy.handle_post_update(
              redun_strat,
              hub_id,
              child_spec.id,
              child_nodes,
              {:up, arg.node}
            )

            # Will initiate the start of the child on the new node.
            Distributor.child_redist_init(hub_id, child_spec, node)

            Task.completed(:ok)
        end
      end)
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

    defp distributed_child_specs(
           %__MODULE__{
             local_children: [{child_id, {child_spec, _child_nodes_old}} | childs],
             dist_strat: dist_strat,
             hub_id: hub_id,
             repl_fact: rp,
             node: node
           } = arg,
           acc
         ) do
      child_nodes = DistributionStrategy.belongs_to(dist_strat, hub_id, child_id, rp)
      local_node = node()

      cond do
        Enum.member?(child_nodes, node) ->
          keep_local = Enum.member?(child_nodes, local_node)

          acc = [
            %{child_spec: child_spec, keep_local: keep_local, child_nodes: child_nodes} | acc
          ]

          distributed_child_specs(%__MODULE__{arg | local_children: childs}, acc)

        true ->
          distributed_child_specs(arg, acc)
      end
    end

    defp distributed_child_specs(_arg, acc), do: acc

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
    def handle(%__MODULE__{} = arg) do
      HookManager.dispatch_hook(
        arg.hub_id,
        Hook.pre_nodes_redistribution(),
        {:nodedown, arg.removed_node}
      )

      distribute_processes(arg)

      State.unlock_local_event_handler(arg.hub_id)

      PartitionToleranceStrategy.handle_node_down(
        arg.partition_strat,
        arg.hub_id,
        arg.removed_node,
        arg.hub_nodes
      )

      HookManager.dispatch_hook(
        arg.hub_id,
        Hook.post_nodes_redistribution(),
        {:nodedown, arg.removed_node}
      )

      HookManager.dispatch_hook(arg.hub_id, Hook.cluster_leave(), arg)

      :ok
    end

    defp distribute_processes(%__MODULE__{} = arg) do
      children = ProcessRegistry.registry(arg.hub_id)

      removed_node_processes(children, arg.removed_node)
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
