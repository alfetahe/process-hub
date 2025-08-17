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
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Constant.Event
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.PriorityLevel
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Handler.ChildrenRem
  alias ProcessHub.Handler.ClusterUpdate
  alias ProcessHub.Handler.Synchronization
  alias ProcessHub.Handler.ChildrenAdd
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.State
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Synchronizer
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.State

  use Event
  use GenServer

  @type t() :: %__MODULE__{
          hub_id: atom(),
          managers: map(),
          storage: map()
        }

  defstruct [
    :hub_id,
    :managers,
    :storage
  ]

  def start_link({_, _, managers, _} = arg) do
    GenServer.start_link(__MODULE__, arg, name: managers.coordinator)
  end

  ##############################################################################
  ### Callbacks
  ##############################################################################

  @impl true
  @spec init({ProcessHub.hub_id(), ProcessHub.t(), map()}) ::
          {:ok, ProcessHub.Coordinator.t(), {:continue, :additional_setup}}
  def init({hub_id, settings, managers, storage}) do
    Process.flag(:trap_exit, true)
    :net_kernel.monitor_nodes(true)

    hub_nodes = get_hub_nodes(hub_id)
    setup_local_storage(settings, hub_nodes, storage)
    init_strategies(hub_id, settings)
    register_handlers(managers)
    register_handlers(hub_id, settings.hooks)

    state = %__MODULE__{
      hub_id: hub_id,
      managers: managers,
      storage: storage
    }

    {:ok, state, {:continue, :additional_setup}}
  end

  @impl true
  def handle_continue(:additional_setup, state) do
    local_store = state.storage.local

    PartitionToleranceStrategy.init(
      Storage.get(local_store, StorageKey.strpart()),
      state.hub_id
    )

    schedule_hub_discovery(Storage.get(local_store, StorageKey.hdi()))
    schedule_sync(Storage.get(local_store, StorageKey.strsyn()))

    # TODO: is it okay to dispatch all nodes?
    Enum.each(Node.list(), fn node ->
      :erlang.send({state.hub_id, node}, {@event_cluster_join, node()}, [])
    end)

    # TODO: handlers are not registered in some cases thats why dispatching may fail..
    # Dispatcher.propagate_event(state.hub_id, @event_cluster_join, node(), %{members: :external})

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    HookManager.dispatch_hook(
      state.hub_id,
      Hook.coordinator_shutdown(),
      reason
    )

    # Notify all the nodes in the cluster that this node is leaving the hub.
    Dispatcher.propagate_event(state.hub_id, @event_cluster_leave, node(), %{
      members: :external,
      priority: PriorityLevel.locked()
    })

    # Terminate all the running tasks before shutting down the coordinator.
    task_sup = state.managers.task_supervisor

    Task.Supervisor.children(task_sup)
    |> Enum.each(fn pid ->
      Task.Supervisor.terminate_child(task_sup, pid)
    end)
  end

  @impl true
  def handle_cast({:start_children, children, start_opts}, state) do
    if length(children) > 0 do
      Task.Supervisor.start_child(
        state.managers.task_supervisor,
        ChildrenAdd.StartHandle,
        :handle,
        [
          %ChildrenAdd.StartHandle{
            hub_id: state.hub_id,
            children: children,
            start_opts: start_opts,
            dist_sup: state.managers.distributed_supervisor,
            task_sup: state.managers.task_supervisor,
            local_storage: state.storage.local
          }
        ]
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:stop_children, children, stop_opts}, state) do
    Task.Supervisor.start_child(
      state.managers.task_supervisor,
      ChildrenRem.StopHandle,
      :handle,
      [
        %ChildrenRem.StopHandle{
          hub_id: state.hub_id,
          children: children,
          stop_opts: stop_opts
        }
      ]
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:exec_cast, {m, f, a}}, state) do
    apply(m, f, a)

    {:noreply, state}
  end

  @impl true
  def handle_call({:init_children_start, child_specs, opts}, _from, state) do
    result =
      Distributor.init_children(
        state.hub_id,
        child_specs,
        Distributor.default_init_opts(opts)
      )

    {:reply, result, state}
  end

  @impl true
  def handle_call({:init_children_stop, child_ids, opts}, _from, state) do
    result =
      Distributor.stop_children(
        state.hub_id,
        child_ids,
        Distributor.default_init_opts(opts)
      )

    {:reply, result, state}
  end

  @impl true
  def handle_call(:is_locked?, _from, state) do
    {:reply, State.is_locked?(state.hub_id), state}
  end

  @impl true
  def handle_call(:is_partitioned?, _from, state) do
    {:reply, State.is_partitioned?(state.hub_id), state}
  end

  @impl true
  def handle_call({:get_nodes, opts}, _from, state) do
    {:reply, Cluster.nodes(state.hub_id, opts), state}
  end

  @impl true
  def handle_call({:promote_to_node, node}, _from, state) do
    {:reply, Cluster.promote_to_node(state.hub_id, node), state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :bong, state}
  end

  @impl true
  def handle_info({@event_cluster_leave, node}, state) do
    {:noreply, handle_node_down(state, node)}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Cluster.propagate_self(state.hub_id, node)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Dispatcher.propagate_event(state.hub_id, @event_cluster_leave, node, %{members: :local})

    {:noreply, state}
  end

  @impl true
  def handle_info({@event_distribute_children, node}, state) do
    Task.Supervisor.start_child(
      state.managers.task_supervisor,
      ClusterUpdate.NodeUp,
      :handle,
      [
        %ClusterUpdate.NodeUp{
          hub_id: state.hub_id,
          node: node
        }
      ]
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({@event_cluster_join, node}, %{hub_id: hub_id} = state) do
    hub_nodes = Cluster.nodes(state.hub_id, [:include_local])

    if Cluster.new_node?(hub_nodes, node) and node() !== node do
      Cluster.add_hub_node(hub_id, node)

      HookManager.dispatch_hook(hub_id, Hook.pre_cluster_join(), node)

      unlock_status =
        PartitionToleranceStrategy.toggle_unlock?(
          Storage.get(state.storage.local, StorageKey.strpart()),
          state.hub_id,
          node
        )

      if unlock_status do
        State.toggle_quorum_success(hub_id)
      end

      # Atomic dispatch with locking.
      Dispatcher.propagate_event(hub_id, @event_distribute_children, node, %{
        members: :local
      })

      State.lock_event_handler(hub_id)
      Cluster.propagate_self(hub_id, node)
      HookManager.dispatch_hook(hub_id, Hook.post_cluster_join(), node)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({@event_sync_remote_children, {children_data, node}}, state) do
    Task.Supervisor.start_child(
      state.managers.task_supervisor,
      Synchronization.ProcessEmitHandle,
      :handle,
      [
        %Synchronization.ProcessEmitHandle{
          hub_id: state.hub_id,
          remote_node: node,
          remote_children: children_data
        }
      ]
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({@event_migration_add, {children, start_opts}}, state) do
    if length(children) > 0 do
      State.lock_event_handler(state.hub_id)

      Task.Supervisor.start_child(
        state.managers.task_supervisor,
        ChildrenAdd.StartHandle,
        :handle,
        [
          %ChildrenAdd.StartHandle{
            hub_id: state.hub_id,
            children: children,
            start_opts: start_opts,
            dist_sup: state.managers.distributed_supervisor,
            task_sup: state.managers.task_supervisor,
            local_storage: state.storage.local
          }
        ]
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({@event_children_registration, {post_start_results, _node, start_opts}}, state) do
    Task.Supervisor.async(
      state.managers.task_supervisor,
      ChildrenAdd.SyncHandle,
      :handle,
      [
        %ChildrenAdd.SyncHandle{
          hub_id: state.hub_id,
          post_start_results: post_start_results,
          start_opts: start_opts
        }
      ]
    )
    |> Task.await()

    {:noreply, state}
  end

  @impl true
  def handle_info({@event_children_unregistration, {children, node, stop_opts}}, state) do
    Task.Supervisor.async(
      state.managers.task_supervisor,
      ChildrenRem.SyncHandle,
      :handle,
      [
        %ChildrenRem.SyncHandle{
          hub_id: state.hub_id,
          children: children,
          node: node,
          stop_opts: stop_opts
        }
      ]
    )
    |> Task.await()

    {:noreply, state}
  end

  @impl true
  def handle_info({@event_child_process_pid_update, {child_id, {node, pid}}}, state) do
    {cs, nodes_pids, metadata} =
      ProcessRegistry.lookup(
        state.hub_id,
        child_id,
        with_metadata: true
      )

    ProcessRegistry.insert(
      state.hub_id,
      cs,
      Keyword.put(nodes_pids, node, pid),
      metadata: metadata
    )

    HookManager.dispatch_hook(
      state.hub_id,
      Hook.child_process_pid_update(),
      {node, pid}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:sync_processes, state) do
    Synchronizer.trigger_sync(
      state.hub_id,
      state.managers.task_supervisor
    )

    state.storage.local
    |> Storage.get(StorageKey.strsyn())
    |> schedule_sync()

    {:noreply, state}
  end

  @impl true
  def handle_info(:propagate, %{hub_id: hub_id} = state) do
    state.storage.local
    |> Storage.get(StorageKey.hdi())
    |> schedule_hub_discovery()

    Dispatcher.propagate_event(hub_id, @event_cluster_join, node(), %{
      members: :external,
      priority: PriorityLevel.locked()
    })

    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, :normal}, state) do
    {:noreply, state}
  end

  @impl true
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

      State.lock_event_handler(state.hub_id)
      hub_nodes = Cluster.rem_hub_node(state.hub_id, down_node)

      Task.Supervisor.start_child(
        state.managers.task_supervisor,
        ClusterUpdate.NodeDown,
        :handle,
        [
          %ClusterUpdate.NodeDown{
            hub_id: state.hub_id,
            removed_node: down_node,
            hub_nodes: hub_nodes
          }
        ]
      )
    end

    state
  end

  defp get_hub_nodes(hub_id) do
    case Cluster.nodes(hub_id, [:include_local]) do
      [] -> [node()]
      nodes -> nodes
    end
  end

  defp init_strategies(hub_id, settings) do
    DistributionStrategy.init(
      settings.distribution_strategy,
      hub_id
    )

    SynchronizationStrategy.init(
      settings.synchronization_strategy,
      hub_id
    )

    MigrationStrategy.init(
      settings.migration_strategy,
      hub_id
    )

    RedundancyStrategy.init(
      settings.redundancy_strategy,
      hub_id
    )
  end

  defp setup_local_storage(%ProcessHub{} = settings, hub_nodes, storage) do
    Storage.insert(storage.local, StorageKey.hn(), hub_nodes)
    Storage.insert(storage.local, StorageKey.strred(), settings.redundancy_strategy)
    Storage.insert(storage.local, StorageKey.strdist(), settings.distribution_strategy)
    Storage.insert(storage.local, StorageKey.strmigr(), settings.migration_strategy)
    Storage.insert(storage.local, StorageKey.staticcs(), settings.child_specs)

    Storage.insert(
      storage.local,
      StorageKey.strsyn(),
      settings.synchronization_strategy
    )

    Storage.insert(
      storage.local,
      StorageKey.strpart(),
      settings.partition_tolerance_strategy
    )

    Storage.insert(storage.local, StorageKey.hdi(), settings.hubs_discover_interval)
    Storage.insert(storage.local, StorageKey.dlrt(), settings.deadlock_recovery_timeout)
    Storage.insert(storage.local, StorageKey.mbt(), settings.migr_base_timeout)
  end

  defp register_handlers(%{event_queue: eq}) do
    Blockade.add_handler(eq, @event_distribute_children)
    Blockade.add_handler(eq, @event_cluster_join)
    Blockade.add_handler(eq, @event_cluster_leave)
    Blockade.add_handler(eq, @event_sync_remote_children)
    Blockade.add_handler(eq, @event_children_registration)
    Blockade.add_handler(eq, @event_children_unregistration)
    Blockade.add_handler(eq, @event_migration_add)
    Blockade.add_handler(eq, @event_child_process_pid_update)
  end

  defp register_handlers(hub_id, hooks) when is_map(hooks) do
    for {hook_key, hook_handlers} <- hooks do
      HookManager.register_handlers(hub_id, hook_key, hook_handlers)
    end
  end

  defp register_handlers(hub_id, _hooks) do
    register_handlers(hub_id, %{})
  end

  defp schedule_sync(sync_strat) do
    Process.send_after(self(), :sync_processes, sync_strat.sync_interval)
  end

  defp schedule_hub_discovery(interval) do
    Process.send_after(self(), :propagate, interval)
  end
end
