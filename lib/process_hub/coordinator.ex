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
  alias ProcessHub.Hub

  use Event
  use GenServer

  def start_link({settings, _, _} = arg) do
    GenServer.start_link(__MODULE__, arg, name: settings.hub_id)
  end

  def get_hub(hub_id) do
    GenServer.call(hub_id, :get_state)
  end

  ##############################################################################
  ### Callbacks
  ##############################################################################

  @impl true
  @spec init({ProcessHub.t(), map(), map()}) :: {:ok, Hub.t(), {:continue, :additional_setup}}
  def init({hub_conf, procs, storage}) do
    Process.flag(:trap_exit, true)
    :net_kernel.monitor_nodes(true)

    # Store the current hub nodes in the misc storage.
    Storage.insert(
      storage.misc,
      StorageKey.hn(),
      get_hub_nodes(storage.misc)
    )

    state = %Hub{
      hub_id: hub_conf.hub_id,
      procs: procs,
      storage: storage
    }

    hub_conf = init_strategies(state, hub_conf)
    register_handlers(procs)
    register_handlers(storage.hook, hub_conf.hooks)
    setup_misc_storage(hub_conf, storage)

    local_store = state.storage.misc
    event_queue = state.procs.event_queue

    # Register the initializer pid on the registry.
    Registry.register(
      state.procs.system_registry,
      "initializer",
      state.procs.initializer
    )

    # Schedule periodic tasks.
    schedule_hub_discovery(Storage.get(local_store, StorageKey.hdi()))
    schedule_sync(Storage.get(local_store, StorageKey.strsyn()))

    # Monitor cluster join events.
    Blockade.monitor_handlers(event_queue, @event_cluster_join)

    # Emit cluster join event.
    Dispatcher.propagate_event(event_queue, @event_cluster_join, node(), %{
      members: :external
    })

    # Make sure we register all joined hub nodes.
    event_queue
    |> Blockade.get_handlers(@event_cluster_join)
    |> elem(1)
    |> join_handlers(state)

    {:ok, state, {:continue, :additional_setup}}
  end

  @impl true
  def handle_continue(:additional_setup, state) do
    # Handle partition strategy initialization. This needs to be done
    # after the coordinator has been started.
    part_strat =
      PartitionToleranceStrategy.init(
        Storage.get(state.storage.misc, StorageKey.strpart()),
        state
      )

    Storage.insert(state.storage.misc, StorageKey.strpart(), part_strat)

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    HookManager.dispatch_hook(
      state.storage.hook,
      Hook.coordinator_shutdown(),
      reason
    )

    # Notify all the nodes in the cluster that this node is leaving the hub.
    Dispatcher.propagate_event(state.procs.event_queue, @event_cluster_leave, node(), %{
      members: :external,
      priority: PriorityLevel.locked()
    })

    # Terminate all the running tasks before shutting down the coordinator.
    task_sup = state.procs.task_sup

    Task.Supervisor.children(task_sup)
    |> Enum.each(fn pid ->
      Task.Supervisor.terminate_child(task_sup, pid)
    end)
  end

  @impl true
  def handle_cast({:start_children, children, start_opts}, state) do
    if length(children) > 0 do
      Task.Supervisor.start_child(
        state.procs.task_sup,
        ChildrenAdd.StartHandle,
        :handle,
        [
          %ChildrenAdd.StartHandle{
            children: children,
            start_opts: start_opts,
            hub: state
          }
        ]
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:stop_children, children, stop_opts}, state) do
    Task.Supervisor.start_child(
      state.procs.task_sup,
      ChildrenRem.StopHandle,
      :handle,
      [
        %ChildrenRem.StopHandle{
          children: children,
          stop_opts: stop_opts,
          hub: state
        }
      ]
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:exec_cast, {m, f, a}}, state) do
    apply(m, f, [state | a])

    {:noreply, state}
  end

  @impl true
  def handle_call({:register_hook_handlers, hook_key, handlers}, _from, state) do
    result = register_handlers(state.storage.hook, %{hook_key => handlers})

    {:reply, result, state}
  end

  @impl true
  def handle_call({:cancel_hook_handlers, hook_key, handler_ids}, _from, state) do
    result = unregister_handlers(state.storage.hook, hook_key, handler_ids)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:init_children_start, child_specs, opts}, _from, state) do
    opts = Keyword.put(opts, :init_cids, Enum.map(child_specs, & &1.id))

    result =
      Distributor.compose_start_request(
        state,
        child_specs,
        Distributor.default_init_opts(opts)
      )

    {:reply, result, state}
  end

  @impl true
  def handle_call({:init_children_stop, child_ids, opts}, _from, state) do
    result =
      Distributor.stop_children(
        state,
        child_ids,
        Distributor.default_init_opts(opts)
      )

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_dist_children, opts}, _from, state) do
    children =
      case Enum.member?(opts, :global) do
        true -> Distributor.which_children_global(state, opts)
        false -> Distributor.which_children_local(state, opts)
      end

    {:reply, children, state}
  end

  @impl true
  def handle_call(:is_locked?, _from, state) do
    {:reply, State.is_locked?(state), state}
  end

  @impl true
  def handle_call(:is_partitioned?, _from, state) do
    {:reply, State.is_partitioned?(state), state}
  end

  @impl true
  def handle_call({:get_nodes, opts}, _from, state) do
    {:reply, Cluster.nodes(state.storage.misc, opts), state}
  end

  @impl true
  def handle_call({:promote_to_node, node}, _from, state) do
    {:reply, Cluster.promote_to_node(state, node), state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
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
  def handle_info({:nodedown, node}, state) do
    # Batch rapid nodedown events together to avoid multiple independent redistributions.
    # When nodes go down rapidly, we collect them and process as a single batch.
    # The batch window ensures all nodedown events from rapid scale-down are captured
    # together, allowing consistent redistribution calculations across all nodes.
    {:noreply, batch_event(state, :nodedown, node)}
  end

  @impl true
  def handle_info({:process_batch, :nodedown}, state) do
    {state, nodes} = take_batch(state, :nodedown)

    if length(nodes) > 0 do
      # Dispatch a single batch event with all down nodes.
      # This ensures we calculate redistribution once based on final cluster state.
      Dispatcher.propagate_event(state.procs.event_queue, @event_cluster_leave_batch, nodes, %{
        members: :local,
        atomic_priority_set: PriorityLevel.locked(),
        local_priority_set: true
      })
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({@event_cluster_leave_batch, nodes}, state) do
    {:noreply, handle_node_down_batch(state, nodes)}
  end

  @impl true
  def handle_info({:nodeup, _node}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({@event_distribute_children, node}, state) do
    Task.Supervisor.start_child(
      state.procs.task_sup,
      ClusterUpdate.NodeUp,
      :handle,
      [
        %ClusterUpdate.NodeUp{
          node: node,
          hub: state
        }
      ]
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({@event_cluster_join, node}, state) do
    # Batch cluster_join events similar to nodedown
    {:noreply, batch_event(state, :cluster_join, node)}
  end

  @impl true
  def handle_info({:process_batch, :cluster_join}, state) do
    {state, nodes} = take_batch(state, :cluster_join)

    if length(nodes) > 0 do
      # Process all joining nodes together
      state = handle_hub_join_batch(state, nodes)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({@event_sync_remote_children, {children_data, node}}, state) do
    Task.Supervisor.start_child(
      state.procs.task_sup,
      Synchronization.ProcessEmitHandle,
      :handle,
      [
        %Synchronization.ProcessEmitHandle{
          hub: state,
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
      State.lock_event_handler(state)

      Task.Supervisor.start_child(
        state.procs.task_sup,
        ChildrenAdd.StartHandle,
        :handle,
        [
          %ChildrenAdd.StartHandle{
            children: children,
            start_opts: start_opts,
            hub: state
          }
        ]
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({@event_children_registration, {post_start_results, _node, start_opts}}, state) do
    Task.Supervisor.async(
      state.procs.task_sup,
      ChildrenAdd.SyncHandle,
      :handle,
      [
        %ChildrenAdd.SyncHandle{
          hub: state,
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
      state.procs.task_sup,
      ChildrenRem.SyncHandle,
      :handle,
      [
        %ChildrenRem.SyncHandle{
          hub: state,
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
    case ProcessRegistry.lookup(
           state.hub_id,
           child_id,
           with_metadata: true
         ) do
      nil ->
        # Child not found in registry, skip update
        {:noreply, state}

      {cs, nodes_pids, metadata} ->
        ProcessRegistry.insert(
          state.hub_id,
          cs,
          Keyword.put(nodes_pids, node, pid),
          metadata: metadata,
          hook_storage: state.storage.hook
        )

        HookManager.dispatch_hook(
          state.storage.hook,
          Hook.child_process_pid_update(),
          {node, pid}
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:sync_processes, state) do
    Synchronizer.trigger_sync(state)

    state.storage.misc
    |> Storage.get(StorageKey.strsyn())
    |> schedule_sync()

    {:noreply, state}
  end

  @impl true
  def handle_info({_ref, :join, @event_cluster_join, handlers}, state) do
    join_handlers(handlers, state)

    {:noreply, state}
  end

  @impl true
  def handle_info({_ref, :leave, @event_cluster_join, _handlers}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:propagate, state) do
    state.storage.misc
    |> Storage.get(StorageKey.hdi())
    |> schedule_hub_discovery()

    Dispatcher.propagate_event(state.procs.event_queue, @event_cluster_join, node(), %{
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

  # Adds a node to the event batch and starts a timer if this is the first event.
  # Returns the updated state.
  @spec batch_event(Hub.t(), atom(), node()) :: Hub.t()
  defp batch_event(state, event_type, node) do
    batch = get_in(state.event_batches, [event_type]) || Hub.default_batch_state()
    batch_window = get_batch_window(state)

    new_batch =
      case batch.timer_ref do
        nil ->
          # First event in batch - start timer
          timer_ref = Process.send_after(self(), {:process_batch, event_type}, batch_window)
          %{nodes: [node], timer_ref: timer_ref}

        _ref ->
          # Add to existing batch
          %{batch | nodes: [node | batch.nodes]}
      end

    put_in(state.event_batches[event_type], new_batch)
  end

  # Takes all nodes from a batch and resets it.
  # Returns {updated_state, nodes_list}.
  @spec take_batch(Hub.t(), atom()) :: {Hub.t(), [node()]}
  defp take_batch(state, event_type) do
    batch = get_in(state.event_batches, [event_type]) || Hub.default_batch_state()
    nodes = batch.nodes
    state = put_in(state.event_batches[event_type], Hub.default_batch_state())
    {state, nodes}
  end

  # Returns the configured batch window in milliseconds from storage.
  defp get_batch_window(state) do
    Storage.get(state.storage.misc, StorageKey.ebd()) || 500
  end

  defp join_handlers(handlers, state) do
    node_list = Node.list()

    Enum.each(handlers, fn handler_pid ->
      node = node(handler_pid)

      if Enum.member?(node_list, node) do
        handle_hub_join(state, node)
      end
    end)
  end

  defp handle_hub_join(state, node) do
    hub_nodes = Cluster.nodes(state.storage.misc, [:include_local])

    if Cluster.new_node?(hub_nodes, node) and node() !== node do
      Cluster.add_hub_node(state.storage.misc, node)

      HookManager.dispatch_hook(state.storage.hook, Hook.pre_cluster_join(), node)

      unlock_status =
        PartitionToleranceStrategy.toggle_unlock?(
          Storage.get(state.storage.misc, StorageKey.strpart()),
          state,
          node
        )

      if unlock_status do
        State.toggle_quorum_success(state)
      end

      # Atomic dispatch with locking.
      # TODO: why not use the dispatch_lock function?
      Dispatcher.propagate_event(state.procs.event_queue, @event_distribute_children, node, %{
        members: :local
      })

      State.lock_event_handler(state)
      HookManager.dispatch_hook(state.storage.hook, Hook.post_cluster_join(), node)
    end
  end

  # Handle multiple nodes joining together (batched).
  defp handle_hub_join_batch(state, nodes) do
    hub_nodes = Cluster.nodes(state.storage.misc, [:include_local])
    local_node = node()

    # Filter to only new nodes (not ourselves and not already in cluster)
    new_nodes =
      Enum.filter(nodes, fn node ->
        Cluster.new_node?(hub_nodes, node) and node !== local_node
      end)

    if length(new_nodes) > 0 do
      # Add all new nodes to cluster state
      Enum.each(new_nodes, fn node ->
        Cluster.add_hub_node(state.storage.misc, node)
      end)

      # Dispatch pre hooks for all nodes
      Enum.each(new_nodes, fn node ->
        HookManager.dispatch_hook(state.storage.hook, Hook.pre_cluster_join(), node)
      end)

      # Check if any node should trigger quorum unlock
      part_strat = Storage.get(state.storage.misc, StorageKey.strpart())

      unlock_status =
        Enum.any?(new_nodes, fn node ->
          PartitionToleranceStrategy.toggle_unlock?(part_strat, state, node)
        end)

      if unlock_status do
        State.toggle_quorum_success(state)
      end

      # Dispatch distribute_children for each new node
      Enum.each(new_nodes, fn node ->
        Dispatcher.propagate_event(state.procs.event_queue, @event_distribute_children, node, %{
          members: :local
        })
      end)

      State.lock_event_handler(state)

      # Dispatch post hooks for all nodes
      Enum.each(new_nodes, fn node ->
        HookManager.dispatch_hook(state.storage.hook, Hook.post_cluster_join(), node)
      end)
    end

    state
  end

  # Handle a single node going down (from explicit @event_cluster_leave).
  # Delegates to the same handler as batched events, but with a single-element list.
  defp handle_node_down(state, down_node) do
    hub_nodes = Cluster.nodes(state.storage.misc, [:include_local])

    if Enum.member?(hub_nodes, down_node) do
      HookManager.dispatch_hook(state.storage.hook, Hook.pre_cluster_leave(), down_node)

      # Lock is already set via atomic_priority_set in {:nodedown} handler,
      # but call again to ensure consistent state for hooks.
      State.lock_event_handler(state)
      Cluster.rem_hub_node(state.storage.misc, down_node)

      # Get current hub_nodes AFTER this node has been removed
      updated_hub_nodes = Cluster.nodes(state.storage.misc, [:include_local])

      Task.Supervisor.start_child(
        state.procs.task_sup,
        fn ->
          # Use the unified handler with single-element list
          ClusterUpdate.NodeDown.handle(%ClusterUpdate.NodeDown{
            removed_nodes: [down_node],
            hub_nodes: updated_hub_nodes,
            hub: state
          })
        end
      )
    else
      # Node not in hub - unlock immediately since we locked at dispatch time
      State.unlock_event_handler(state)
    end

    state
  end

  # Handle multiple nodes going down together (batched).
  # This removes all nodes from cluster state first, then does ONE redistribution.
  defp handle_node_down_batch(state, down_nodes) do
    hub_nodes = Cluster.nodes(state.storage.misc, [:include_local])

    # Filter to only nodes that are actually in the hub
    valid_down_nodes = Enum.filter(down_nodes, &Enum.member?(hub_nodes, &1))

    if length(valid_down_nodes) > 0 do
      # Dispatch pre hooks for all nodes
      Enum.each(valid_down_nodes, fn node ->
        HookManager.dispatch_hook(state.storage.hook, Hook.pre_cluster_leave(), node)
      end)

      State.lock_event_handler(state)

      # Remove ALL down nodes from cluster state FIRST
      Enum.each(valid_down_nodes, fn node ->
        Cluster.rem_hub_node(state.storage.misc, node)
      end)

      # Get updated hub_nodes AFTER all nodes have been removed
      updated_hub_nodes = Cluster.nodes(state.storage.misc, [:include_local])

      # Start a single task that handles all down nodes together
      Task.Supervisor.start_child(
        state.procs.task_sup,
        fn ->
          # Use unified handler that processes all nodes in one pass
          ClusterUpdate.NodeDown.handle(%ClusterUpdate.NodeDown{
            removed_nodes: valid_down_nodes,
            hub_nodes: updated_hub_nodes,
            hub: state
          })
        end
      )
    else
      # No valid nodes - unlock since we locked at dispatch time
      State.unlock_event_handler(state)
    end

    state
  end

  defp get_hub_nodes(misc_storage) do
    case Cluster.nodes(misc_storage, [:include_local]) do
      [] -> [node()]
      nodes -> nodes
    end
  end

  defp init_strategies(hub, %ProcessHub{} = hub_conf) do
    dist_strat =
      DistributionStrategy.init(
        hub_conf.distribution_strategy,
        hub
      )

    sync_strat =
      SynchronizationStrategy.init(
        hub_conf.synchronization_strategy,
        hub
      )

    migr_strat =
      MigrationStrategy.init(
        hub_conf.migration_strategy,
        hub
      )

    redun_strat =
      RedundancyStrategy.init(
        hub_conf.redundancy_strategy,
        hub
      )

    %ProcessHub{
      hub_conf
      | distribution_strategy: dist_strat,
        synchronization_strategy: sync_strat,
        migration_strategy: migr_strat,
        redundancy_strategy: redun_strat
    }
  end

  defp setup_misc_storage(%ProcessHub{} = settings, storage) do
    Storage.insert(storage.misc, StorageKey.strred(), settings.redundancy_strategy)
    Storage.insert(storage.misc, StorageKey.strdist(), settings.distribution_strategy)
    Storage.insert(storage.misc, StorageKey.strmigr(), settings.migration_strategy)
    Storage.insert(storage.misc, StorageKey.staticcs(), settings.child_specs)

    Storage.insert(
      storage.misc,
      StorageKey.strsyn(),
      settings.synchronization_strategy
    )

    Storage.insert(
      storage.misc,
      StorageKey.strpart(),
      settings.partition_tolerance_strategy
    )

    Storage.insert(storage.misc, StorageKey.hdi(), settings.hubs_discover_interval)
    Storage.insert(storage.misc, StorageKey.dlrt(), settings.deadlock_recovery_timeout)
    Storage.insert(storage.misc, StorageKey.mbt(), settings.migr_base_timeout)
    Storage.insert(storage.misc, StorageKey.ebd(), settings.event_batch_delay)
  end

  defp register_handlers(%{event_queue: eq}) do
    Blockade.add_handler(eq, @event_distribute_children)
    Blockade.add_handler(eq, @event_cluster_join)
    Blockade.add_handler(eq, @event_cluster_leave)
    Blockade.add_handler(eq, @event_cluster_leave_batch)
    Blockade.add_handler(eq, @event_sync_remote_children)
    Blockade.add_handler(eq, @event_children_registration)
    Blockade.add_handler(eq, @event_children_unregistration)
    Blockade.add_handler(eq, @event_migration_add)
    Blockade.add_handler(eq, @event_child_process_pid_update)
  end

  defp register_handlers(hook_storage, hooks) when is_map(hooks) do
    for {hook_key, hook_handlers} <- hooks do
      HookManager.register_handlers(hook_storage, hook_key, hook_handlers)
    end
  end

  defp register_handlers(hook_storage, _hooks) do
    register_handlers(hook_storage, %{})
  end

  defp unregister_handlers(hook_storage, hook_key, handler_ids) do
    for handler_id <- handler_ids do
      HookManager.cancel_handler(hook_storage, hook_key, handler_id)
    end
  end

  defp schedule_sync(sync_strat) do
    Process.send_after(self(), :sync_processes, sync_strat.sync_interval)
  end

  defp schedule_hub_discovery(interval) do
    Process.send_after(self(), :propagate, interval)
  end
end
