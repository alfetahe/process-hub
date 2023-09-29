defmodule ProcessHub.Handler.ClusterUpdate do
  @moduledoc false

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.Event
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.Ring
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.Synchronizer
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.State
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
            hash_ring_old: :hash_ring.ring(),
            hash_ring_new: :hash_ring.ring(),
            new_node: node(),
            cluster_nodes: [node()]
          }

    @enforce_keys [
      :hub_id,
      :redun_strat,
      :sync_strat,
      :migr_strat,
      :partition_strat,
      :hash_ring_old,
      :hash_ring_new,
      :new_node,
      :cluster_nodes
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = args) do
      HookManager.dispatch_hook(
        args.hub_id,
        Hook.pre_nodes_redistribution(),
        {:nodeup, args.new_node}
      )

      distribute_processes(
        args.hub_id,
        args.new_node,
        args.redun_strat,
        args.sync_strat,
        args.migr_strat,
        args.hash_ring_old,
        args.hash_ring_new
      )
      |> Task.await_many(migration_timeout(args.migr_strat))

      propagate_local_children(args.hub_id, args.new_node)

      HookManager.dispatch_hook(
        args.hub_id,
        Hook.post_nodes_redistribution(),
        {:nodeup, args.new_node}
      )

      State.unlock_local_event_handler(args.hub_id)

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

    defp distribute_processes(
           hub_id,
           added_node,
           redun_strat,
           sync_strat,
           migr_strat,
           old_hash_ring,
           hash_ring
         ) do
      local_children(hub_id)
      |> distributed_child_specs(hash_ring, redun_strat, added_node, [])
      |> Enum.map(fn %{child_spec: child_spec, keep_local: keep_local} ->
        case keep_local do
          false ->
            Task.async(fn ->
              MigrationStrategy.handle_migration(
                migr_strat,
                hub_id,
                child_spec,
                added_node,
                sync_strat
              )
            end)

          true ->
            # Sends redundancy mode update message to the running process.
            RedundancyStrategy.handle_post_update(
              redun_strat,
              hub_id,
              child_spec.id,
              {hash_ring, old_hash_ring}
            )

            # Will initiate the start of the child on the new node.
            Distributor.child_redist_init(hub_id, child_spec, added_node)

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

    defp distributed_child_specs([], _hash_ring, _redun_strat, _node, acc) do
      acc
    end

    defp distributed_child_specs(
           [{child_id, {child_spec, _child_nodes_old}} | childs],
           hash_ring,
           redun_strat,
           node,
           acc
         ) do
      child_nodes = RedundancyStrategy.belongs_to(redun_strat, hash_ring, child_id)

      local_node = node()

      cond do
        Enum.member?(child_nodes, node) ->
          keep_local = Enum.member?(child_nodes, local_node)

          distributed_child_specs(childs, hash_ring, redun_strat, node, [
            %{child_spec: child_spec, keep_local: keep_local} | acc
          ])

        true ->
          distributed_child_specs(childs, hash_ring, redun_strat, node, acc)
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
            cluster_nodes: [node()],
            old_hash_ring: :hash_ring.ring(),
            new_hash_ring: :hash_ring.ring(),
            partition_strat: PartitionToleranceStrategy.t(),
            redun_strategy: RedundancyStrategy.t()
          }

    @enforce_keys [
      :hub_id,
      :removed_node,
      :cluster_nodes,
      :old_hash_ring,
      :new_hash_ring,
      :partition_strat,
      :redun_strategy
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = args) do
      HookManager.dispatch_hook(args.hub_id, Hook.pre_nodes_redistribution(), args.removed_node)
      distribute_processes(args)

      PartitionToleranceStrategy.handle_node_down(
        args.partition_strat,
        args.hub_id,
        args.removed_node,
        args.cluster_nodes
      )

      HookManager.dispatch_hook(args.hub_id, Hook.post_nodes_redistribution(), args.removed_node)

      :ok
    end

    defp distribute_processes(%__MODULE__{} = args) do
      children = ProcessRegistry.registry(args.hub_id)

      replication_factor = RedundancyStrategy.replication_factor(args.redun_strategy)

      removed_node_processes(children, args.removed_node)
      |> Enum.each(fn {_, {child_spec, _}} ->
        RedundancyStrategy.handle_post_update(
          args.redun_strategy,
          args.hub_id,
          child_spec.id,
          {args.new_hash_ring, args.old_hash_ring}
        )

        # Check if removed nodes procsses should be started on the local node.
        if Ring.key_to_nodes(args.new_hash_ring, child_spec.id, replication_factor)
           |> Enum.member?(node()) do
          Distributor.child_redist_init(args.hub_id, child_spec, node())
        end
      end)
    end

    defp removed_node_processes(children, removed_node) do
      Enum.filter(children, fn {_child_id, {_child_spec, child_nodes}} ->
        Enum.member?(Keyword.keys(child_nodes), removed_node)
      end)
    end
  end
end
