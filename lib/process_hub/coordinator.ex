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
  `ProcessHub` instance, such as initial synchronization, propagation, etc.
  """

  require Logger
  alias :blockade, as: Blockade
  alias ProcessHub.Constant.Event
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.PriorityLevel
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Handler.ChildrenRem
  alias ProcessHub.Handler.ClusterUpdate
  alias ProcessHub.Handler.Synchronization
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.LocalStorage
  alias ProcessHub.Service.State
  alias ProcessHub.Service.TaskManager
  alias ProcessHub.Utility.Name

  @propagation_interval 10000

  use Event
  use GenServer

  @type t() :: %__MODULE__{
          hub_id: atom(),
          settings: ProcessHub.t(),
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
    :managers,
    :storage
  ]

  def start_link({hub_id, settings, managers}) do
    hub = %__MODULE__{
      hub_id: hub_id,
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
          process_registry: Name.registry(hub.hub_id),
          local: Name.local_storage(hub.hub_id)
        }
    }

    hub_nodes = get_hub_nodes(hub.hub_id)
    setup_local_storage(hub, hub_nodes)
    init_distribution(hub)
    register_handlers(hub.managers)
    register_hook_handlers(hub.hub_id, hub.settings.hooks)

    {:ok, state, {:continue, :additional_setup}}
  end

  def terminate(_reason, state) do
    local_node = node()

    # Notify all the nodes in the cluster that this node is leaving the hub.
    Enum.each(Cluster.nodes(state.hub_id), fn node ->
      Node.spawn(node, fn ->
        if Process.whereis(state.managers.coordinator) do
          Process.send(state.managers.coordinator, {@event_cluster_leave, local_node}, [])
        end
      end)
    end)

    # Terminate all the running tasks before shutting down the coordinator.
    task_sup = state.managers.task_supervisor

    Task.Supervisor.children(task_sup)
    |> Enum.each(fn pid ->
      Task.Supervisor.terminate_child(task_sup, pid)
    end)
  end

  def handle_continue(:additional_setup, state) do
    PartitionToleranceStrategy.handle_startup(
      state.settings.partition_tolerance_strategy,
      state.hub_id
    )

    schedule_propagation()
    schedule_sync(state.settings.synchronization_strategy)

    # TODO: handlers are not registered in some cases thats why dispatching may fail..
    # Dispatcher.propagate_event(state.hub_id, @event_cluster_join, node(), :global)
    # Make sure it's okay to dispatch all nodes
    Enum.each(Node.list(), fn node ->
      :erlang.send({state.managers.coordinator, node}, {@event_cluster_join, node()}, [])
    end)

    {:noreply, state}
  end

  def handle_cast({:start_children, children, start_opts}, state) do
    TaskManager.start_children(state.hub_id, children, start_opts)

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

  def handle_call(:ping, _from, state) do
    {:reply, :bong, state}
  end

  def handle_info({@event_cluster_leave, node}, state) do
    {:noreply, handle_node_down(state, node)}
  end

  def handle_info({:nodeup, node}, state) do
    Cluster.propagate_self(state.hub_id, node)

    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    Dispatcher.propagate_event(state.hub_id, @event_cluster_leave, node, :local)

    {:noreply, state}
  end

  def handle_info({@event_distribute_children, node}, state) do
    Task.Supervisor.start_child(
      state.managers.task_supervisor,
      ClusterUpdate.NodeUp,
      :handle,
      [
        %ClusterUpdate.NodeUp{
          hub_id: state.hub_id,
          node: node,
          redun_strat: state.settings.redundancy_strategy,
          migr_strat: state.settings.migration_strategy,
          sync_strat: state.settings.synchronization_strategy,
          partition_strat: state.settings.partition_tolerance_strategy,
          dist_strat: state.settings.distribution_strategy
        }
      ]
    )

    {:noreply, state}
  end

  def handle_info({@event_cluster_join, node}, state) do
    hub_nodes = Cluster.nodes(state.hub_id, [:include_local])

    state =
      if Cluster.new_node?(hub_nodes, node) and node() !== node do
        Cluster.add_hub_node(state.hub_id, node)

        HookManager.dispatch_hook(state.hub_id, Hook.pre_cluster_join(), node)

        PartitionToleranceStrategy.handle_node_up(
          state.settings.partition_tolerance_strategy,
          state.hub_id,
          node
        )

        # Atomic dispatch with locking.
        Dispatcher.propagate_event(state.hub_id, @event_distribute_children, node, :local, %{
          atomic_priority_set: PriorityLevel.locked()
        })

        Cluster.propagate_self(state.hub_id, node)
        HookManager.dispatch_hook(state.hub_id, Hook.post_cluster_join(), node)

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

  def handle_info({@event_migration_add, {children, start_opts}}, state) do
    if length(children) > 0 do
      State.lock_local_event_handler(state.hub_id)
    end

    TaskManager.start_children(state.hub_id, children, start_opts)

    {:noreply, state}
  end

  def handle_info({@event_children_registration, {children, _node}}, state) do
    TaskManager.local_reg_insert(state.hub_id, children)

    {:noreply, state}
  end

  def handle_info({@event_children_unregistration, {children, node}}, state) do
    Task.Supervisor.async(
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
    |> Task.await()

    {:noreply, state}
  end

  def handle_info(:sync_processes, state) do
    Task.Supervisor.start_child(
      state.managers.task_supervisor,
      Synchronization.IntervalSyncInit,
      :handle,
      [
        %Synchronization.IntervalSyncInit{
          hub_id: state.hub_id,
          sync_strat: state.settings.synchronization_strategy
        }
      ]
    )

    schedule_sync(state.settings.synchronization_strategy)

    {:noreply, state}
  end

  def handle_info(:propagate, state) do
    schedule_propagation()

    Dispatcher.propagate_event(state.hub_id, @event_cluster_join, node(), :global)

    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("Unhandled message: #{inspect(msg)}")

    {:noreply, state}
  end

  ##############################################################################
  ### Private functions
  ##############################################################################

  defp handle_node_down(state, down_node) do
    hub_nodes = Cluster.nodes(state.hub_id, [:include_local])

    if Enum.member?(hub_nodes, down_node) do
      HookManager.dispatch_hook(state.hub_id, Hook.pre_cluster_leave(), down_node)

      State.lock_local_event_handler(state.hub_id)
      hub_nodes = Cluster.rem_hub_node(state.hub_id, down_node)

      Task.Supervisor.start_child(
        state.managers.task_supervisor,
        ClusterUpdate.NodeDown,
        :handle,
        [
          %ClusterUpdate.NodeDown{
            hub_id: state.hub_id,
            removed_node: down_node,
            partition_strat: state.settings.partition_tolerance_strategy,
            redun_strategy: state.settings.redundancy_strategy,
            dist_strat: state.settings.distribution_strategy,
            hub_nodes: hub_nodes
          }
        ]
      )

      state
    else
      state
    end
  end

  defp get_hub_nodes(hub_id) do
    case Cluster.nodes(hub_id, [:include_local]) do
      [] -> [node()]
      nodes -> nodes
    end
  end

  defp init_distribution(hub) do
    DistributionStrategy.init(
      hub.settings.distribution_strategy,
      hub.hub_id
    )
  end

  defp setup_local_storage(hub, hub_nodes) do
    strategies = hub.settings

    LocalStorage.insert(hub.hub_id, :hub_nodes, hub_nodes)
    LocalStorage.insert(hub.hub_id, :redundancy_strategy, strategies.redundancy_strategy)
    LocalStorage.insert(hub.hub_id, :distribution_strategy, strategies.distribution_strategy)
    LocalStorage.insert(hub.hub_id, :migration_strategy, strategies.migration_strategy)

    LocalStorage.insert(
      hub.hub_id,
      :synchronization_strategy,
      strategies.synchronization_strategy
    )

    LocalStorage.insert(
      hub.hub_id,
      :partition_tolerance_strategy,
      strategies.partition_tolerance_strategy
    )
  end

  defp register_handlers(%{global_event_queue: gq, local_event_queue: lq}) do
    Blockade.add_handler(lq, @event_distribute_children)
    Blockade.add_handler(gq, @event_cluster_join)
    Blockade.add_handler(lq, @event_cluster_leave)
    Blockade.add_handler(lq, @event_sync_remote_children)
    Blockade.add_handler(gq, @event_children_registration)
    Blockade.add_handler(gq, @event_children_unregistration)
    Blockade.add_handler(lq, @event_migration_add)
  end

  defp register_hook_handlers(hub_id, hooks) when is_map(hooks) do
    for {hook_key, hook_handlers} <- hooks do
      HookManager.register_hook_handlers(hub_id, hook_key, hook_handlers)
    end
  end

  defp register_hook_handlers(hub_id, _hooks) do
    register_hook_handlers(hub_id, %{})
  end

  defp schedule_sync(sync_strat) do
    Process.send_after(self(), :sync_processes, sync_strat.sync_interval)
  end

  defp schedule_propagation() do
    Process.send_after(self(), :propagate, @propagation_interval)
  end
end
