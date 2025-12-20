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
  alias ProcessHub.StartChildrenRequest
  alias ProcessHub.StartChildrenRequest.NodeStartRequest
  alias ProcessHub.StopChildrenRequest
  alias ProcessHub.StopChildrenRequest.NodeStopRequest
  alias ProcessHub.Hub

  # TODO: make configurable.
  # Pending request management
  @cleanup_interval :timer.minutes(1)

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
    schedule_request_cleanup()

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

  # New pattern - receives NodeStartRequest struct directly
  @impl true
  def handle_cast({:start_children, %NodeStartRequest{children: children} = request}, state) do
    if length(children) > 0 do
      Task.Supervisor.start_child(
        state.procs.task_sup,
        ChildrenAdd.StartHandle,
        :handle,
        [
          %ChildrenAdd.StartHandle{
            children: children,
            node_start_request: request,
            hub: state
          }
        ]
      )
    end

    {:noreply, state}
  end

  # TODO: remove in future versions
  # Legacy pattern - receives children list and start_opts separately
  @impl true
  def handle_cast({:start_children, children, start_opts}, state) when is_list(children) do
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

  # New pattern - receives NodeStopRequest struct directly
  @impl true
  def handle_cast({:stop_children, %NodeStopRequest{children: children} = request}, state) do
    if length(children) > 0 do
      Task.Supervisor.start_child(
        state.procs.task_sup,
        ChildrenRem.StopHandle,
        :handle,
        [
          %ChildrenRem.StopHandle{
            children: children,
            node_stop_request: request,
            hub: state
          }
        ]
      )
    end

    {:noreply, state}
  end

  # TODO: remove in future versions
  # Legacy pattern - receives children list and stop_opts separately
  @impl true
  def handle_cast({:stop_children, children, stop_opts}, state) when is_list(children) do
    if length(children) > 0 do
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
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:exec_cast, {m, f, a}}, state) do
    apply(m, f, [state | a])

    {:noreply, state}
  end

  @impl true
  def handle_cast({:start_children_response, transaction_id, response_node, results}, state) do
    case get_pending_request(state, transaction_id) do
      nil ->
        # Request already completed or expired
        {:noreply, state}

      request ->
        updated_request =
          StartChildrenRequest.record_node_response(request, response_node, results)

        # Check if all nodes responded
        if StartChildrenRequest.all_nodes_responded?(updated_request) do
          # Build result and check if rollback is needed
          result = StartChildrenRequest.to_start_result(updated_request)
          on_failure = Keyword.get(updated_request.options, :on_failure, :continue)

          final_result =
            if on_failure == :rollback and result.status == :error do
              perform_start_rollback(state, result)
            else
              result
            end

          # If someone is waiting, reply to them
          if updated_request.awaiter do
            GenServer.reply(updated_request.awaiter, final_result)
          end

          # Always cleanup when all nodes have responded
          {:noreply, remove_pending_request(state, transaction_id)}
        else
          {:noreply, update_pending_request(state, updated_request)}
        end
    end
  end

  @impl true
  def handle_cast({:stop_children_response, transaction_id, response_node, results}, state) do
    case get_pending_stop_request(state, transaction_id) do
      nil ->
        # Request already completed or expired
        {:noreply, state}

      request ->
        updated_request =
          StopChildrenRequest.record_node_response(request, response_node, results)

        # Check if all nodes responded
        if StopChildrenRequest.all_nodes_responded?(updated_request) do
          # If someone is waiting, reply to them
          if updated_request.awaiter do
            GenServer.reply(
              updated_request.awaiter,
              StopChildrenRequest.to_stop_result(updated_request)
            )
          end

          # Always cleanup when all nodes have responded
          {:noreply, remove_pending_stop_request(state, transaction_id)}
        else
          {:noreply, update_pending_stop_request(state, updated_request)}
        end
    end
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
    opts =
      opts
      |> Keyword.put(:init_cids, Enum.map(child_specs, & &1.id))
      |> Distributor.default_init_opts()

    case Distributor.compose_start_request(state, child_specs, opts) do
      {:ok, start_request} ->
        new_state = store_pending_request(state, start_request)

        # Return Future if awaitable: true or async_wait: true (deprecated)
        result =
          if Keyword.get(opts, :awaitable, false) or Keyword.get(opts, :async_wait, false) do
            start_request.future
          else
            :start_initiated
          end

        {:reply, {:ok, result}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:init_children_stop, child_ids, opts}, _from, state) do
    opts = Distributor.default_init_opts(opts)

    case Distributor.compose_stop_request(state, child_ids, opts) do
      {:ok, stop_request} ->
        new_state = store_pending_stop_request(state, stop_request)

        # Return Future if awaitable: true or async_wait: true (deprecated)
        result =
          if Keyword.get(opts, :awaitable, false) or Keyword.get(opts, :async_wait, false) do
            stop_request.future
          else
            :stop_initiated
          end

        {:reply, {:ok, result}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:await_start_result, transaction_id}, from, state) do
    case get_pending_request(state, transaction_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      request ->
        timeout = Keyword.get(request.options, :timeout, 5000)

        cond do
          StartChildrenRequest.all_nodes_responded?(request) ->
            # All nodes responded - return result immediately and cleanup
            result = StartChildrenRequest.to_start_result(request)
            new_state = remove_pending_request(state, transaction_id)
            {:reply, result, new_state}

          timeout == 0 ->
            # Timeout is 0 - return immediately with what we have (non-responded = timeout errors)
            result = StartChildrenRequest.to_start_result(request)
            new_state = remove_pending_request(state, transaction_id)
            {:reply, result, new_state}

          true ->
            # Not all nodes responded yet - store awaiter and defer reply
            updated_request = StartChildrenRequest.set_awaiter(request, from)
            new_state = update_pending_request(state, updated_request)
            Process.send_after(self(), {:await_timeout, transaction_id, from}, timeout)
            {:noreply, new_state}
        end
    end
  end

  @impl true
  def handle_call({:await_stop_result, transaction_id}, from, state) do
    case get_pending_stop_request(state, transaction_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      request ->
        timeout = Keyword.get(request.options, :timeout, 5000)

        cond do
          StopChildrenRequest.all_nodes_responded?(request) ->
            # All nodes responded - return result immediately and cleanup
            result = StopChildrenRequest.to_stop_result(request)
            new_state = remove_pending_stop_request(state, transaction_id)
            {:reply, result, new_state}

          timeout == 0 ->
            # Timeout is 0 - return immediately with what we have (non-responded = timeout errors)
            result = StopChildrenRequest.to_stop_result(request)
            new_state = remove_pending_stop_request(state, transaction_id)
            {:reply, result, new_state}

          true ->
            # Not all nodes responded yet - store awaiter and defer reply
            updated_request = StopChildrenRequest.set_awaiter(request, from)
            new_state = update_pending_stop_request(state, updated_request)
            Process.send_after(self(), {:await_stop_timeout, transaction_id, from}, timeout)
            {:noreply, new_state}
        end
    end
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

    # Validate: only process nodes that are actually disconnected
    current_connected = Node.list()

    valid_down_nodes =
      Enum.filter(nodes, fn node ->
        not Enum.member?(current_connected, node)
      end)

    if length(valid_down_nodes) > 0 do
      # Dispatch a single batch event with all validated down nodes.
      # This ensures we calculate redistribution once based on final cluster state.
      Dispatcher.propagate_event(
        state.procs.event_queue,
        @event_cluster_leave_batch,
        valid_down_nodes,
        %{
          members: :local,
          atomic_priority_set: PriorityLevel.locked(),
          local_priority_set: true
        }
      )
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
  def handle_info({@event_distribute_children, nodes}, state) do
    Task.Supervisor.start_child(
      state.procs.task_sup,
      ClusterUpdate.NodeUp,
      :handle,
      [
        %ClusterUpdate.NodeUp{
          nodes: nodes,
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

    # Validate: only process nodes that are still connected
    current_connected = Node.list()

    valid_join_nodes =
      Enum.filter(nodes, fn node ->
        Enum.member?(current_connected, node)
      end)

    if length(valid_join_nodes) > 0 do
      # Process all validated joining nodes together
      state = handle_hub_join_batch(state, valid_join_nodes)
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
  def handle_info({@event_node_join_sync, {sync_data, remote_node}}, state) do
    sync_strategy = Storage.get(state.storage.misc, StorageKey.strsyn())
    SynchronizationStrategy.handle_node_join_data(sync_strategy, state, sync_data, remote_node)

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
  def handle_info({:await_timeout, transaction_id, from}, state) do
    case get_pending_request(state, transaction_id) do
      nil ->
        # Already completed and removed
        {:noreply, state}

      request ->
        # Check if awaiter is still the same (hasn't been replaced or already replied)
        if request.awaiter == from do
          # Timeout reached - return whatever we have
          GenServer.reply(from, StartChildrenRequest.to_start_result(request))
          new_state = remove_pending_request(state, transaction_id)
          {:noreply, new_state}
        else
          # Awaiter changed or already handled
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:await_stop_timeout, transaction_id, from}, state) do
    case get_pending_stop_request(state, transaction_id) do
      nil ->
        # Already completed and removed
        {:noreply, state}

      request ->
        # Check if awaiter is still the same (hasn't been replaced or already replied)
        if request.awaiter == from do
          # Timeout reached - return whatever we have
          GenServer.reply(from, StopChildrenRequest.to_stop_result(request))
          new_state = remove_pending_stop_request(state, transaction_id)
          {:noreply, new_state}
        else
          # Awaiter changed or already handled
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info(:cleanup_expired_requests, state) do
    # Clean up expired start requests
    pending_start =
      state.pending_requests
      |> Enum.reject(fn {_id, request} -> StartChildrenRequest.expired?(request) end)
      |> Map.new()

    # Clean up expired stop requests
    pending_stop =
      state.pending_stop_requests
      |> Enum.reject(fn {_id, request} -> StopChildrenRequest.expired?(request) end)
      |> Map.new()

    schedule_request_cleanup()

    {:noreply, %{state | pending_requests: pending_start, pending_stop_requests: pending_stop}}
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
    debounce_delay = get_debounce_delay(state)

    # Cancel existing timer if present (true debounce - reset on each event)
    if batch.timer_ref do
      Process.cancel_timer(batch.timer_ref)
    end

    # Always start a new timer (resets the debounce window)
    timer_ref = Process.send_after(self(), {:process_batch, event_type}, debounce_delay)

    # Deduplicate nodes in batch
    nodes =
      if Enum.member?(batch.nodes, node) do
        batch.nodes
      else
        [node | batch.nodes]
      end

    new_batch = %{nodes: nodes, timer_ref: timer_ref}
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

  # Returns the configured debounce delay in milliseconds from storage.
  defp get_debounce_delay(state) do
    Storage.get(state.storage.misc, StorageKey.ced()) || 200
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
      Dispatcher.propagate_event(state.procs.event_queue, @event_distribute_children, [node], %{
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

    # Filter to only new nodes.
    new_nodes =
      Enum.filter(nodes, fn node ->
        Cluster.new_node?(hub_nodes, node) and node !== local_node
      end)

    if length(new_nodes) > 0 do
      # Add all new nodes to cluster state
      Enum.each(new_nodes, fn node ->
        Cluster.add_hub_node(state.storage.misc, node)
      end)

      # Broadcast local registry data to joining nodes
      broadcast_local_registry(state, new_nodes)

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

      # Dispatch distribute_children with all new nodes
      Dispatcher.propagate_event(
        state.procs.event_queue,
        @event_distribute_children,
        new_nodes,
        %{
          members: :local
        }
      )

      State.lock_event_handler(state)

      # Dispatch post hooks for all nodes
      Enum.each(new_nodes, fn node ->
        HookManager.dispatch_hook(state.storage.hook, Hook.post_cluster_join(), node)
      end)
    end

    state
  end

  # Broadcasts local registry data to the specified target nodes.
  # Called when new nodes join the cluster.
  defp broadcast_local_registry(state, target_nodes) do
    sync_strategy = Storage.get(state.storage.misc, StorageKey.strsyn())
    local_data = Synchronizer.local_sync_data(state)

    SynchronizationStrategy.broadcast_local_data(
      sync_strategy,
      state,
      local_data,
      target_nodes
    )
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
    Storage.insert(storage.misc, StorageKey.ced(), settings.cluster_event_debounce)
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
    Blockade.add_handler(eq, @event_node_join_sync)
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

  defp store_pending_request(state, %ProcessHub.StartChildrenRequest{} = request) do
    pending = Map.put(state.pending_requests, request.transaction_id, request)
    %{state | pending_requests: pending}
  end

  defp get_pending_request(state, transaction_id) do
    Map.get(state.pending_requests, transaction_id)
  end

  defp update_pending_request(state, %ProcessHub.StartChildrenRequest{} = request) do
    pending = Map.put(state.pending_requests, request.transaction_id, request)
    %{state | pending_requests: pending}
  end

  defp remove_pending_request(state, transaction_id) do
    pending = Map.delete(state.pending_requests, transaction_id)
    %{state | pending_requests: pending}
  end

  defp store_pending_stop_request(state, %ProcessHub.StopChildrenRequest{} = request) do
    pending = Map.put(state.pending_stop_requests, request.transaction_id, request)
    %{state | pending_stop_requests: pending}
  end

  defp get_pending_stop_request(state, transaction_id) do
    Map.get(state.pending_stop_requests, transaction_id)
  end

  defp update_pending_stop_request(state, %ProcessHub.StopChildrenRequest{} = request) do
    pending = Map.put(state.pending_stop_requests, request.transaction_id, request)
    %{state | pending_stop_requests: pending}
  end

  defp remove_pending_stop_request(state, transaction_id) do
    pending = Map.delete(state.pending_stop_requests, transaction_id)
    %{state | pending_stop_requests: pending}
  end

  # Performs rollback by stopping all successfully started children
  # Called when on_failure: :rollback is set and some children failed to start
  defp perform_start_rollback(state, start_result) do
    alias ProcessHub.DistributedSupervisor

    # Extract successfully started child IDs
    success_cids = Enum.map(start_result.started, fn {cid, _nodes} -> cid end)

    if length(success_cids) > 0 do
      # For rollback, we need synchronous cleanup. Instead of going through
      # the async sync strategy, we directly:
      # 1. Terminate each child process
      # 2. Remove from registry directly
      Enum.each(success_cids, fn cid ->
        # Terminate the child process
        DistributedSupervisor.terminate_child(state.procs.dist_sup, cid)
        # Directly remove from registry (synchronous)
        ProcessRegistry.delete(state.hub_id, cid)
      end)
    end

    # Return result with rollback flag set
    %{start_result | rollback: true}
  end

  defp schedule_request_cleanup do
    Process.send_after(self(), :cleanup_expired_requests, @cleanup_interval)
  end
end
