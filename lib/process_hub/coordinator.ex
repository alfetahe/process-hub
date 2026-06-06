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

  alias :blockade, as: Blockade
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Constant.Event
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.State
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.Synchronizer
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.RequestManager
  alias ProcessHub.Service.LoggerService
  alias ProcessHub.Service.Recovery
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
  @spec init({ProcessHub.t(), map(), map()}) ::
          {:ok, Hub.t(), {:continue, :additional_setup}} | {:stop, term()}
  def init({hub_conf, procs, storage}) do
    Process.flag(:trap_exit, true)
    :net_kernel.monitor_nodes(true)

    # Store the current hub nodes in the misc storage.
    Storage.insert(
      storage.misc,
      StorageKey.hn(),
      get_hub_nodes(storage.misc)
    )

    case Recovery.parse_config(Map.get(hub_conf, :auto_recovery, false)) do
      {:ok, recovery_config} ->
        do_init(hub_conf, procs, storage, recovery_config)

      {:error, {:invalid_auto_recovery, _} = reason} ->
        {:stop, reason}

      {:error, :invalid_auto_recovery} ->
        LoggerService.warning(
          "Invalid :auto_recovery config — falling back to disabled",
          %{},
          prefix: "Coordinator"
        )

        do_init(hub_conf, procs, storage, Recovery.disabled_config())
    end
  end

  defp do_init(hub_conf, procs, storage, recovery_config) do
    {marker, recovery_state, resolved_mode} =
      Recovery.init_marker(hub_conf.hub_id, Map.get(hub_conf, :recovery_marker), recovery_config.enabled?)

    state = %Hub{
      hub_id: hub_conf.hub_id,
      procs: procs,
      storage: storage,
      recovery_config: recovery_config,
      recovery_state: recovery_state,
      recovery_marker: marker
    }

    hub_conf = init_strategies(state, hub_conf)
    register_handlers(procs)
    register_handlers(storage.hook, hub_conf.hooks)
    setup_misc_storage(hub_conf, storage)

    Registry.register(state.procs.system_registry, "initializer", state.procs.initializer)

    schedule_hub_discovery(Storage.get(state.storage.misc, StorageKey.hdi()))
    schedule_sync(Storage.get(state.storage.misc, StorageKey.strsyn()))
    schedule_request_cleanup(state)

    Blockade.monitor_handlers(state.procs.event_queue, @event_cluster_join)

    boot_handlers =
      state.procs.event_queue
      |> Blockade.get_handlers(@event_cluster_join)
      |> elem(1)

    LoggerService.info(
      "boot: cluster_join handlers known to pg @nodes | connected @connected | recovery @rs",
      %{
        "nodes" => handler_nodes(boot_handlers),
        "connected" => Node.list(),
        "rs" => recovery_state
      },
      prefix: "Coordinator"
    )

    state = join_handlers(boot_handlers, state)

    state = maybe_start_recovery_window(state)
    state = Recovery.start(state, resolved_mode)

    {:ok, state, {:continue, :additional_setup}}
  end

  # Peer-mode-exchange window is used only when the marker gate is
  # explicitly disabled (back-compat opt-out path).
  defp maybe_start_recovery_window(
         %Hub{recovery_state: :recovery_pending, recovery_marker: %{enabled?: false}} = state
       ) do
    timer =
      Process.send_after(self(), :recovery_window_elapsed, state.recovery_config.recovery_window_ms)

    %{state | recovery_window_timer: timer}
  end

  defp maybe_start_recovery_window(state), do: state

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
      %{reason: reason}
    )

    # Notify all the nodes in the cluster that this node is leaving the hub.
    Dispatcher.dispatch_event(state.procs.event_queue, @event_cluster_leave, node(), %{
      members: :external
    })

    # Terminate all the running tasks before shutting down the coordinator.
    task_sup = state.procs.task_sup

    Task.Supervisor.children(task_sup)
    |> Enum.each(fn pid ->
      Task.Supervisor.terminate_child(task_sup, pid)
    end)

    # Close the registry backend after the rest of teardown completed.
    case Map.get(state.storage, :registry_backend) do
      {module, ref} ->
        Storage.unregister_backend(state.hub_id)
        module.close(ref)

      _ ->
        :ok
    end
  end

  @impl true
  def handle_cast({:exec_cast, {m, f, a}}, state) do
    apply(m, f, [state | a])

    {:noreply, state}
  end

  @impl true
  def handle_cast({:operation_response, transaction_id, response_node, results}, state) do
    RequestManager.handle_response(state, transaction_id, response_node, results)
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

    case Distributor.compose_start_operation(state, child_specs, opts) do
      {:ok, operation} ->
        new_state = RequestManager.store(state, operation)

        # Return Future if awaitable: true or async_wait: true (deprecated)
        result =
          if Keyword.get(opts, :awaitable, false) or Keyword.get(opts, :async_wait, false) do
            operation.future
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

    case Distributor.compose_stop_operation(state, child_ids, opts) do
      {:ok, operation} ->
        new_state = RequestManager.store(state, operation)

        # Return Future if awaitable: true or async_wait: true (deprecated)
        result =
          if Keyword.get(opts, :awaitable, false) or Keyword.get(opts, :async_wait, false) do
            operation.future
          else
            :stop_initiated
          end

        {:reply, {:ok, result}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:await_result, transaction_id}, from, state) do
    RequestManager.handle_await(state, transaction_id, from)
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
  def handle_call(:is_locked?, _from, state) do
    {:reply, state.pending_work_count > 0, state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :bong, state}
  end

  @impl true
  def handle_call(:get_recovery_state, _from, state) do
    {:reply, state.recovery_state, state}
  end

  @impl true
  def handle_info({@event_requests_handle, requests}, state) do
    {:noreply, delegate_work(state, {:handle_requests, requests, state})}
  end

  @impl true
  def handle_info({@event_cluster_leave, node} = msg, state) do
    if Recovery.gate_closed?(state) do
      {:noreply, Recovery.enqueue(state, msg)}
    else
      {:noreply, batch_event(state, :cluster_leave, node)}
    end
  end

  @impl true
  def handle_info({:nodedown, node} = msg, state) do
    state = cancel_nodeup_reconcile(state, node)

    if Recovery.gate_closed?(state) do
      {:noreply, Recovery.enqueue(state, msg)}
    else
      {:noreply, batch_event(state, :nodedown, node)}
    end
  end

  @impl true
  def handle_info({:process_batch, :nodedown}, state) do
    {state, nodes} = take_batch(state, :nodedown)

    current_connected = Node.list()

    # Only process nodes that are actually disconnected.
    valid_down_nodes =
      Enum.filter(nodes, fn node ->
        not Enum.member?(current_connected, node)
      end)

    if length(valid_down_nodes) > 0 do
      Dispatcher.dispatch_event(
        state.procs.event_queue,
        @event_cluster_leave_batch,
        valid_down_nodes,
        %{members: :local}
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:process_batch, :cluster_leave}, state) do
    {state, nodes} = take_batch(state, :cluster_leave)

    if length(nodes) > 0 do
      # Graceful leaves don't need connection validation (the node announced
      # its departure before shutting down), so dispatch them directly.
      Dispatcher.dispatch_event(
        state.procs.event_queue,
        @event_cluster_leave_batch,
        nodes,
        %{members: :local}
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({@event_cluster_leave_batch, nodes}, state) do
    {:noreply, process_node_down_batch(state, nodes)}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    LoggerService.info(
      "nodeup @node | external cluster_join members @ext | connected @connected",
      %{
        "node" => node,
        "ext" => external_hub_nodes(state),
        "connected" => Node.list()
      },
      prefix: "Coordinator"
    )

    # pg scopes aren't synced yet at :nodeup; defer the merge to a fail-safe
    # timer that re-runs it once pg has settled, covering a missed :join.
    {:noreply, schedule_nodeup_reconcile(state, node)}
  end

  @impl true
  def handle_info({:nodeup_reconcile, node}, state) do
    state = cancel_nodeup_reconcile(state, node)

    # Merge only a genuine same-hub peer: one still connected that registered
    # our cluster_join pg handler (what :join relies on). Anything else — e.g.
    # a node not running our hub — is never added to the batch.
    if Enum.member?(external_hub_nodes(state), node) do
      {:noreply, batch_event(state, :cluster_join, node)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({@event_cluster_heartbeat, peer}, state) when is_atom(peer) do
    {:noreply, reconcile_presence(state, peer)}
  end

  @impl true
  def handle_info({@event_node_restarted, peer} = msg, state) when is_atom(peer) do
    {:noreply, Recovery.handle_restart_signal(state, peer, msg)}
  end

  @impl true
  def handle_info({:process_batch, :cluster_join}, state) do
    {state, nodes} = take_batch(state, :cluster_join)

    # Only process nodes that are still connected.
    current_connected = Node.list()

    valid_join_nodes =
      Enum.filter(nodes, fn node ->
        Enum.member?(current_connected, node)
      end)

    state =
      if length(valid_join_nodes) > 0 do
        # The normal path is merging these nodes, so their fail-safe timers
        # are redundant.
        state = cancel_nodeup_reconciles(state, valid_join_nodes)

        # While in :recovery_pending, ask the joining peer for its current
        # recovery state so we can decide whether to defer or replay.
        if state.recovery_state == :recovery_pending do
          Recovery.dispatch_query(state, valid_join_nodes)
        end

        # Always announce our own current recovery state to the joining
        # peer(s) so peers in :recovery_pending see it.
        if state.recovery_config.enabled? do
          Recovery.dispatch_announce(state, valid_join_nodes)
        end

        process_hub_join(state, valid_join_nodes)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({@event_recovery_state_query, from_node}, state) do
    # Respond directly to the asking node with our current recovery state.
    Recovery.dispatch_announce(state, [from_node])
    {:noreply, state}
  end

  @impl true
  def handle_info({@event_recovery_state_announce, {peer_node, peer_state}}, state)
      when peer_node !== node() do
    state = put_in(state.recovery_peers[peer_node], peer_state)

    case Recovery.compute_transition(state.recovery_state, peer_state) do
      {:transition, :normal, reason} ->
        {:noreply, transition_to_normal_from_pending(state, reason)}

      :no_change ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({@event_recovery_state_announce, _payload}, state) do
    # Ignore announces from ourselves.
    {:noreply, state}
  end

  @impl true
  def handle_info(:start_marker_replay, %Hub{recovery_state: :recovery_pending} = state),
    do: {:noreply, Recovery.spawn_replay(state)}

  def handle_info(:start_marker_replay, state), do: {:noreply, state}

  @impl true
  def handle_info({:marker_replay_done, result}, state)
      when state.recovery_state in [:recovery_pending, :recovering] do
    Recovery.emit_replay_complete(state, result)
    {:noreply, Recovery.open_gate(state, :replay_complete)}
  end

  def handle_info({:marker_replay_done, _result}, state), do: {:noreply, state}

  @impl true
  def handle_info(:recovery_timeout_elapsed, state)
      when state.recovery_state in [:recovery_pending, :recovering] do
    Recovery.emit_replay_timeout(state)
    {:noreply, Recovery.open_gate(state, :recovery_timeout)}
  end

  def handle_info(:recovery_timeout_elapsed, state), do: {:noreply, state}

  @impl true
  def handle_info(:recovery_window_elapsed, %Hub{recovery_state: :recovery_pending} = state) do
    state = %{state | recovery_window_timer: nil}

    if Recovery.any_peer_normal?(state.recovery_peers) do
      # A peer-normal announce was already processed but we still got here
      # (race). Skip replay, transition directly.
      {:noreply, transition_to_normal_from_pending(state, :peer_normal)}
    else
      {:noreply, run_replay_and_transition(state)}
    end
  end

  @impl true
  def handle_info(:recovery_window_elapsed, state) do
    # Timer fired but state already moved on. No-op.
    {:noreply, state}
  end

  @impl true
  def handle_info({@event_node_registry_broadcast, {sync_data, remote_node}}, state) do
    sync_strategy = Storage.get(state.storage.misc, StorageKey.strsyn())
    SynchronizationStrategy.handle_node_join_data(sync_strategy, state, sync_data, remote_node)

    {:noreply, state}
  end

  @impl true
  def handle_info(:sync_processes, state) do
    state = delegate_work(state, {:handle_work, fn -> Synchronizer.trigger_sync(state) end})

    state.storage.misc
    |> Storage.get(StorageKey.strsyn())
    |> schedule_sync()

    {:noreply, state}
  end

  @impl true
  # This is the mechanism that handles new nodes joining the cluster as
  # observed through pg's cluster_join handlers.
  # Here we know that the remote nodes connected are also running the same `:hub_id`
  # instances since they are the ones that registered the handlers.
  def handle_info({_ref, :join, @event_cluster_join, handlers}, state) do
    LoggerService.info(
      "pg cluster_join handlers JOINED @nodes | connected @connected",
      %{"nodes" => handler_nodes(handlers), "connected" => Node.list()},
      prefix: "Coordinator"
    )

    {:noreply, join_handlers(handlers, state)}
  end

  @impl true
  def handle_info({_ref, :leave, @event_cluster_join, handlers}, state) do
    LoggerService.info(
      "pg cluster_join handlers LEFT @nodes | connected @connected",
      %{"nodes" => handler_nodes(handlers), "connected" => Node.list()},
      prefix: "Coordinator"
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:propagate, state) do
    state.storage.misc
    |> Storage.get(StorageKey.hdi())
    |> schedule_hub_discovery()

    Dispatcher.dispatch_event(state.procs.event_queue, @event_cluster_heartbeat, node(), %{
      members: :external
    })

    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, :normal}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:await_timeout, transaction_id, from}, state) do
    RequestManager.handle_timeout(state, transaction_id, from)
  end

  @impl true
  def handle_info(:cleanup_expired_requests, state) do
    schedule_request_cleanup(state)
    {:noreply, RequestManager.cleanup_expired(state)}
  end

  @impl true
  def handle_info({:post_action_callback, m, f, a}, state) do
    apply(m, f, [state | a])
    {:noreply, state}
  end

  @impl true
  def handle_info(:work_complete, state) do
    {:noreply, %{state | pending_work_count: max(0, state.pending_work_count - 1)}}
  end

  @impl true
  def handle_info(msg, state) do
    LoggerService.warning("Unhandled message: @message", %{"message" => msg},
      prefix: "Coordinator"
    )

    {:noreply, state}
  end

  ##############################################################################
  ### Private functions
  ##############################################################################

  defp delegate_work(state, message) do
    GenServer.cast(state.procs.worker_queue, {:tracked, message, self()})
    %{state | pending_work_count: state.pending_work_count + 1}
  end

  # ---- Recovery transition helpers ------------------------------------------

  defp transition_to_normal_from_pending(%Hub{} = state, reason) do
    if state.recovery_window_timer do
      Process.cancel_timer(state.recovery_window_timer)
    end

    state = %{state | recovery_state: :normal, recovery_window_timer: nil}

    Recovery.dispatch_state_changed_hook(state, :recovery_pending, :normal, reason)

    if state.recovery_config.enabled? do
      Recovery.dispatch_announce(state, :external)
    end

    state
  end

  defp run_replay_and_transition(%Hub{} = state) do
    # :recovery_pending → :recovering
    state = %{state | recovery_state: :recovering}
    Recovery.dispatch_state_changed_hook(state, :recovery_pending, :recovering, :window_elapsed)

    if state.recovery_config.enabled? do
      Recovery.dispatch_announce(state, :external)
    end

    result = Recovery.replay(state, state.recovery_config)

    # :recovering → :normal
    state = %{state | recovery_state: :normal}
    Recovery.dispatch_state_changed_hook(state, :recovering, :normal, result.reason)

    if state.recovery_config.enabled? do
      Recovery.dispatch_announce(state, :external)
    end

    state
  end

  # A presence announce merges only a node we don't already track, so a
  # steady-state heartbeat is a silent no-op.
  defp reconcile_presence(state, peer) do
    cond do
      not Cluster.new_node?(Cluster.nodes(state.storage.misc, [:include_local]), peer) -> state
      Recovery.gate_closed?(state) -> Recovery.enqueue(state, {@event_cluster_heartbeat, peer})
      true -> batch_event(state, :cluster_join, peer)
    end
  end

  @doc false
  def process_hub_join(hub, nodes) do
    hub_nodes = Cluster.nodes(hub.storage.misc, [:include_local])
    local_node = node()

    new_nodes =
      Enum.filter(nodes, fn n ->
        Cluster.new_node?(hub_nodes, n) and n !== local_node
      end)

    if length(new_nodes) > 0 do
      LoggerService.info(
        "hub merge: adding nodes @new (current membership @existing)",
        %{"new" => new_nodes, "existing" => hub_nodes},
        prefix: "Coordinator"
      )

      # Broadcast local registry data to joining nodes.
      Synchronizer.broadcast_local_registry(hub, new_nodes)

      delegate_work(hub, {:handle_node_up, %{joined_nodes: new_nodes, hub: hub}})
    else
      hub
    end
  end

  @doc false
  def process_node_down_batch(hub, down_nodes) do
    hub_nodes = Cluster.nodes(hub.storage.misc, [:include_local])

    # Filter to only nodes that are actually in the hub.
    valid_down_nodes = Enum.filter(down_nodes, &Enum.member?(hub_nodes, &1))

    if length(valid_down_nodes) > 0 do
      delegate_work(hub, {:handle_node_down, %{removed_nodes: valid_down_nodes, hub: hub}})
    else
      hub
    end
  end

  # Adds a node to the event batch and (re)schedules the flush timer with a
  # bounded total wait, so a sustained event stream cannot starve the batch.
  # Returns the updated state.
  @spec batch_event(Hub.t(), atom(), node()) :: Hub.t()
  defp batch_event(state, event_type, node) do
    batch = get_in(state.event_batches, [event_type]) || Hub.default_batch_state()
    debounce_delay = get_debounce_delay(state)
    max_wait = max_batch_wait(debounce_delay)
    now = System.monotonic_time(:millisecond)

    started_at = batch.started_at || now
    remaining_window = max(0, max_wait - (now - started_at))
    delay = min(debounce_delay, remaining_window)

    if batch.timer_ref do
      Process.cancel_timer(batch.timer_ref)
    end

    timer_ref = Process.send_after(self(), {:process_batch, event_type}, delay)

    # Deduplicate nodes in batch
    nodes =
      if Enum.member?(batch.nodes, node) do
        batch.nodes
      else
        [node | batch.nodes]
      end

    new_batch = %{nodes: nodes, timer_ref: timer_ref, started_at: started_at}
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
    Storage.get(state.storage.misc, StorageKey.ced()) || 500
  end

  # Derived upper bound on how long a single batch window may grow before it
  # MUST flush, regardless of fresh events. A small multiple of the configured
  # debounce keeps the cap intuitively close to user intent while guaranteeing
  # the batch is processed in bounded time.
  defp max_batch_wait(0), do: 0
  defp max_batch_wait(debounce) when debounce > 0, do: max(debounce * 4, debounce + 500)

  # Nodes hosting the given handler pids, deduped (used for formation logging).
  defp handler_nodes(handlers) do
    handlers |> Enum.map(&node/1) |> Enum.uniq()
  end

  # Remote nodes pg currently resolves as cluster_join handlers. An empty list
  # while a peer is in `Node.list()` means the pg scope never synced.
  defp external_hub_nodes(state) do
    state.procs.event_queue
    |> Blockade.get_handlers(@event_cluster_join)
    |> elem(1)
    |> handler_nodes()
    |> Enum.reject(&(&1 == node()))
  end

  defp join_handlers(handlers, state) do
    node_list = Node.list()

    # Collect all valid nodes from handlers
    nodes =
      handlers
      |> Enum.map(fn handler_pid -> node(handler_pid) end)
      |> Enum.filter(fn n -> Enum.member?(node_list, n) end)
      |> Enum.uniq()

    if length(nodes) > 0 do
      Enum.reduce(nodes, state, fn node, acc_state ->
        batch_event(acc_state, :cluster_join, node)
      end)
    else
      state
    end
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
    Storage.insert(storage.misc, StorageKey.mbt(), settings.migr_base_timeout)
    Storage.insert(storage.misc, StorageKey.ced(), settings.cluster_event_debounce)
    Storage.insert(storage.misc, StorageKey.cnrt(), settings.cross_node_request_timeout)
    Storage.insert(storage.misc, StorageKey.rci(), settings.req_cleanup_interval)
    Storage.insert(storage.misc, StorageKey.nri(), settings.nodeup_reconcile_interval)
  end

  defp register_handlers(%{event_queue: eq}) do
    Blockade.add_handler(eq, @event_cluster_join)
    Blockade.add_handler(eq, @event_cluster_heartbeat)
    Blockade.add_handler(eq, @event_node_restarted)
    Blockade.add_handler(eq, @event_cluster_leave)
    Blockade.add_handler(eq, @event_cluster_leave_batch)
    Blockade.add_handler(eq, @event_node_registry_broadcast)
    Blockade.add_handler(eq, @event_requests_handle)
    Blockade.add_handler(eq, @event_recovery_state_announce)
    Blockade.add_handler(eq, @event_recovery_state_query)
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

  # Per-node membership reconciliation fail-safe (0 disables). Re-arms cleanly
  # on flapping by cancelling any pending timer for the node first.
  defp schedule_nodeup_reconcile(state, node) do
    case Storage.get(state.storage.misc, StorageKey.nri()) || 0 do
      interval when interval > 0 ->
        state = cancel_nodeup_reconcile(state, node)
        ref = Process.send_after(self(), {:nodeup_reconcile, node}, interval)
        put_in(state.nodeup_reconcile_timers[node], ref)

      _ ->
        state
    end
  end

  defp cancel_nodeup_reconcile(state, node) do
    case Map.pop(state.nodeup_reconcile_timers, node) do
      {nil, _} ->
        state

      {ref, rest} ->
        Process.cancel_timer(ref)
        %{state | nodeup_reconcile_timers: rest}
    end
  end

  defp cancel_nodeup_reconciles(state, nodes) do
    Enum.reduce(nodes, state, fn n, acc -> cancel_nodeup_reconcile(acc, n) end)
  end

  defp schedule_request_cleanup(state) do
    interval = Storage.get(state.storage.misc, StorageKey.rci())
    Process.send_after(self(), :cleanup_expired_requests, interval)
  end
end
