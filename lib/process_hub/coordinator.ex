defmodule ProcessHub.Coordinator do
  @moduledoc """
  The `ProcessHub` coordinator module is responsible for coordinating most of the `ProcessHub` events and work.

  In most cases, the coordinator module delegates the work to other service-based
  modules or handler processes that are created on demand.

  Each `ProcessHub` instance has its own coordinator process that handles the
  coordination. These processes are supervised by the `ProcessHub.Initializer`
  supervisor.

  The coordinator stores state about the `ProcessHub` instance, such as the cluster nodes.

  Additionally, the coordinator takes care of any periodic tasks required by the
  `ProcessHub` instance, such as `:ets` table cleanups, initial synchronization, propagation, etc.
  """

  alias :blockade, as: Blockade
  alias :hash_ring, as: HashRing
  alias :hash_ring_node, as: HashRingNode
  alias ProcessHub.Constant.Event
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Handler.ChildrenAdd
  alias ProcessHub.Handler.ChildrenRem
  alias ProcessHub.Handler.ClusterUpdate
  alias ProcessHub.Handler.Synchronization
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.LocalStorage
  alias ProcessHub.Service.Ring
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.State

  @cleanup_interval 10000
  @propagation_interval 10000

  use Event
  use GenServer

  @type t() :: %__MODULE__{
          hub_id: atom(),
          settings: ProcessHub.t(),
          cluster_nodes: [node()],
          hash_ring: HashRing.ring(),
          managers: %{
            coordinator: atom(),
            distributed_supervisor: atom(),
            local_event_queue: atom(),
            global_event_queue: atom(),
            task_supervisor: atom()
          },
          storage: %{
            process_registry: reference(),
            local: reference()
          }
        }

  defstruct [
    :hub_id,
    :settings,
    :cluster_nodes,
    :hash_ring,
    :managers,
    :storage
  ]

  def start_link({hub_id, settings, managers}) do
    hub = %__MODULE__{
      hub_id: hub_id,
      cluster_nodes: [node()],
      settings: settings,
      managers: managers
    }

    GenServer.start_link(__MODULE__, hub, name: managers.coordinator)
  end

  ##############################################################################
  ### Callbacks
  ##############################################################################

  def init(hub) do
    Process.flag(:trap_exit, true)
    :net_kernel.monitor_nodes(true)

    state = %__MODULE__{
      hub
      | storage: %{
          process_registry: ProcessRegistry.registry_name(hub.hub_id),
          local: hub.hub_id
        },
        hash_ring: HashRing.make([HashRingNode.make(node())])
    }

    register_handlers(hub.managers)
    register_hooks(hub.hub_id, hub.settings.hooks)

    {:ok, state, {:continue, :additional_setup}}
  end

  def terminate(_reason, state) do
    local_node = node()

    Enum.each(state.cluster_nodes, fn node ->
      Node.spawn(node, fn ->
        if Process.whereis(state.managers.coordinator) do
          Process.send(state.managers.coordinator, {@event_cluster_leave, local_node}, [])
        end
      end)
    end)
  end

  def handle_continue(:additional_setup, state) do
    PartitionToleranceStrategy.handle_startup(
      state.settings.partition_tolerance_strategy,
      state.hub_id,
      state.cluster_nodes
    )

    schedule_cleanup()
    schedule_propagation()
    schedule_sync(state.settings.synchronization_strategy)

    # TODO: handlers are not registered in some cases thats why dispatching may fail..
    # Dispatcher.propagate_event(state.hub_id, @event_cluster_join, node(), :global)
    Enum.each(Node.list(), fn node ->
      :erlang.send({state.managers.coordinator, node}, {@event_cluster_join, node()}, [])
    end)

    {:noreply, state}
  end

  def handle_cast({:start_children, children}, state) do
    Task.Supervisor.start_child(
      state.managers.task_supervisor,
      ChildrenAdd.StartHandle,
      :handle,
      [
        %ChildrenAdd.StartHandle{
          hub_id: state.hub_id,
          children: children,
          hash_ring: state.hash_ring,
          dist_sup: state.managers.distributed_supervisor,
          sync_strategy: state.settings.synchronization_strategy,
          redun_strategy: state.settings.redundancy_strategy
        }
      ]
    )

    {:noreply, state}
  end

  def handle_cast({:stop_children, children}, state) do
    Task.Supervisor.start_child(
      state.managers.task_supervisor,
      ChildrenRem.StopHandle,
      :handle,
      [
        %ChildrenRem.StopHandle{
          hub_id: state.hub_id,
          children: children,
          dist_sup: state.managers.distributed_supervisor,
          sync_strategy: state.settings.synchronization_strategy
        }
      ]
    )

    {:noreply, state}
  end

  def handle_cast({:handle_sync, strategy, sync_data, remote_node}, state) do
    Task.Supervisor.start_child(
      state.managers.task_supervisor,
      Synchronization.IntervalSyncHandle,
      :handle,
      [
        %Synchronization.IntervalSyncHandle{
          hub_id: state.hub_id,
          sync_strat: strategy,
          sync_data: sync_data,
          remote_node: remote_node
        }
      ]
    )

    {:noreply, state}
  end

  def handle_call(:strategies, _from, state) do
    {:reply, state.settings, state}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:cluster_nodes, _from, state) do
    {:reply, state.cluster_nodes, state}
  end

  def handle_call(:get_ring, _from, state) do
    {:reply, state.hash_ring, state}
  end

  def handle_info({@event_cluster_leave, node}, state) do
    {:noreply, handle_node_down(state, node)}
  end

  def handle_info({:nodeup, node}, state) do
    Cluster.propagate_self(state.hub_id, node)

    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    {:noreply, handle_node_down(state, node)}
  end

  def handle_info({@event_distribute_children, node}, state) do
    Task.Supervisor.start_child(
      state.managers.task_supervisor,
      ClusterUpdate.NodeUp,
      :handle,
      [
        %ClusterUpdate.NodeUp{
          hub_id: state.hub_id,
          redun_strat: state.settings.redundancy_strategy,
          migr_strat: state.settings.migration_strategy,
          sync_strat: state.settings.synchronization_strategy,
          partition_strat: state.settings.partition_tolerance_strategy,
          hash_ring_old: Ring.remove_node(state.hash_ring, node),
          hash_ring_new: state.hash_ring,
          new_node: node,
          cluster_nodes: state.cluster_nodes
        }
      ]
    )

    {:noreply, state}
  end

  def handle_info({@event_cluster_join, node}, state) do
    state =
      if Cluster.new_node?(state.cluster_nodes, node) do
        state = %__MODULE__{
          state
          | hash_ring: Ring.add_node(state.hash_ring, node),
            cluster_nodes: Cluster.add_cluster_node(state.cluster_nodes, node)
        }

        PartitionToleranceStrategy.handle_node_up(
          state.settings.partition_tolerance_strategy,
          state.hub_id,
          node,
          state.cluster_nodes
        )

        Dispatcher.propagate_event(state.hub_id, @event_distribute_children, node, :local)
        State.lock_local_event_handler(state.hub_id)
        Cluster.propagate_self(state.hub_id, node)
        HookManager.dispatch_hook(state.hub_id, Hook.cluster_join(), node)

        state
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({@event_sync_remote_children, {child_specs, node}}, state) do
    Task.Supervisor.start_child(
      state.managers.task_supervisor,
      Synchronization.ProcessEmitHandle,
      :handle,
      [
        %Synchronization.ProcessEmitHandle{
          hub_id: state.hub_id,
          remote_node: node,
          remote_children: child_specs
        }
      ]
    )

    {:noreply, state}
  end

  def handle_info({@event_children_registration, {children, _node}}, state) do
    Task.Supervisor.async_nolink(
      state.managers.task_supervisor,
      ChildrenAdd.SyncHandle,
      :handle,
      [
        %ChildrenAdd.SyncHandle{
          hub_id: state.hub_id,
          children: children
        }
      ]
    )
    |> Task.await()

    {:noreply, state}
  end

  def handle_info({@event_children_unregistration, {children, node}}, state) do
    Task.Supervisor.start_child(
      state.managers.task_supervisor,
      ChildrenRem.SyncHandle,
      :handle,
      [
        %ChildrenRem.SyncHandle{
          hub_id: state.hub_id,
          children: children,
          node: node
        }
      ]
    )

    {:noreply, state}
  end

  def handle_info(:sync_processes, state) do
    sync_strategy = state.settings.synchronization_strategy

    Task.Supervisor.start_child(
      state.managers.task_supervisor,
      Synchronization.IntervalSyncInit,
      :handle,
      [
        %Synchronization.IntervalSyncInit{
          hub_id: state.hub_id,
          sync_strat: sync_strategy,
          cluster_nodes: state.cluster_nodes
        }
      ]
    )

    schedule_sync(sync_strategy)

    {:noreply, state}
  end

  def handle_info(:local_storage_cleanup, state) do
    cache_cleanup(state.storage.local)
    schedule_cleanup()

    {:noreply, state}
  end

  def handle_info(:propagate, state) do
    schedule_propagation()

    Dispatcher.propagate_event(state.hub_id, @event_cluster_join, node(), :global)

    {:noreply, state}
  end

  ##############################################################################
  ### Private functions
  ##############################################################################

  defp handle_node_down(state, down_node) do
    cluster_nodes = Cluster.rem_cluster_node(state.cluster_nodes, down_node)

    old_hash_ring = state.hash_ring
    new_hash_ring = Ring.remove_node(old_hash_ring, down_node)

    state = %__MODULE__{
      state
      | hash_ring: new_hash_ring,
        cluster_nodes: cluster_nodes
    }

    Task.Supervisor.start_child(
      state.managers.task_supervisor,
      ClusterUpdate.NodeDown,
      :handle,
      [
        %ClusterUpdate.NodeDown{
          hub_id: state.hub_id,
          removed_node: down_node,
          cluster_nodes: state.cluster_nodes,
          old_hash_ring: old_hash_ring,
          new_hash_ring: new_hash_ring,
          partition_strat: state.settings.partition_tolerance_strategy,
          redun_strategy: state.settings.redundancy_strategy
        }
      ]
    )

    HookManager.dispatch_hook(state.hub_id, Hook.cluster_leave(), down_node)

    state
  end

  defp cache_cleanup(ets_table) do
    table_data = :ets.tab2list(ets_table)
    timestamp = DateTime.to_unix(DateTime.utc_now())

    Enum.filter(table_data, fn
      {_, _, nil} -> false
      {_, _, ttl} -> is_number(ttl) && ttl < timestamp
    end)
    |> Enum.each(fn {key, _, _} ->
      :ets.delete(ets_table, key)
    end)
  end

  defp register_handlers(%{global_event_queue: gq, local_event_queue: lq}) do
    Blockade.add_handler(lq, @event_distribute_children)
    Blockade.add_handler(gq, @event_cluster_join)
    Blockade.add_handler(lq, @event_sync_remote_children)
    Blockade.add_handler(gq, @event_children_registration)
    Blockade.add_handler(gq, @event_children_unregistration)
  end

  defp register_hooks(hub_id, hooks) when is_map(hooks) do
    LocalStorage.insert(hub_id, HookManager.cache_key(), hooks)
  end

  defp register_hooks(hub_id, _hooks) do
    register_hooks(hub_id, %{})
  end

  defp schedule_sync(sync_strat) do
    Process.send_after(self(), :sync_processes, sync_strat.sync_interval)
  end

  defp schedule_cleanup() do
    Process.send_after(self(), :local_storage_cleanup, @cleanup_interval)
  end

  defp schedule_propagation() do
    Process.send_after(self(), :propagate, @propagation_interval)
  end
end
