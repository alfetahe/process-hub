defmodule ProcessHub.Strategy.Migration.HotSwap do
  @moduledoc """
  The hot swap migration strategy implements the `ProcessHub.Strategy.Migration.Base` protocol.
  It provides a migration strategy where the local process is terminated after the new one is
  started on the remote node and registered.

  Hot swap is useful when we want to ensure that there is no downtime when migrating
  the child process to the remote node. The old process remains alive until the new process
  is successfully registered, at which point the state is delivered and the old process
  is terminated.

  This is the key difference from ColdSwap, which terminates the local process before
  starting the remote one.

  ## State Handover

  When `handover: true` is set, HotSwap will:
  1. Query state from local processes before sending start requests
  2. Store states in ETS with TTL (along with old process reference)
  3. Send start requests to new nodes
  4. When new processes are registered, deliver stored state via hook
  5. Terminate the old local process after state delivery

  To use state handover, your GenServer must `use ProcessHub.Strategy.Migration.HotSwap`:

      defmodule MyServer do
        use GenServer
        use ProcessHub.Strategy.Migration.HotSwap

        # Optionally override these callbacks:
        # def prepare_handover_state(state), do: state
        # def alter_handover_state(_current, handover), do: handover
      end

  > #### State Handover with Replication {: .warning}
  >
  > State handover is **not supported** when using the `ProcessHub.Strategy.Redundancy.Replication`
  > strategy. With replication, multiple instances of a process run across the cluster, making
  > state handover semantics undefined. If you attempt to use `handover: true` with replication,
  > the hub will fail to start with `{:error, {:invalid_config, :handover_with_replication_not_supported}}`.
  """

  require Logger

  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Strategy.Migration.HotSwap
  alias ProcessHub.Utility.Extractor
  alias ProcessHub.Utility.Bag

  @typedoc """
  The hot swap migration struct.

  Options:
  - `:handover` - Enable state handover before termination (default: false)
  - `:state_ttl` - TTL for stored states in milliseconds (default: 30000)
  - `:state_query_timeout` - Timeout for querying state from local process (default: 5000)
  """
  @type t() :: %__MODULE__{
          handover: boolean(),
          state_ttl: pos_integer(),
          state_query_timeout: pos_integer()
        }

  defstruct handover: false,
            state_ttl: 30000,
            state_query_timeout: 5000

  # TTL for graceful shutdown state storage (longer than regular migration)
  @graceful_shutdown_ttl :timer.seconds(60)

  @doc """
  Handles registry_pid_inserted hook to deliver stored state to new processes
  and terminate the old local process.
  """
  def handle_registry_insert(_strategy, hub, {child_id, node_pids}) do
    case Storage.get(hub.storage.misc, {:hotswap_state, child_id}) do
      nil ->
        :ok

      {state, old_pid} ->
        # Send state to new process(es)
        Enum.each(node_pids, fn {_node, pid} ->
          if is_pid(pid) do
            send(pid, {:process_hub, :hotswap_handover, child_id, state})
          end
        end)

        # Terminate the old local process - this is the key difference from ColdSwap
        if is_pid(old_pid) and Process.alive?(old_pid) do
          DistributedSupervisor.terminate_child(hub.procs.dist_sup, child_id)
        end

        # Cleanup stored state
        Storage.remove(hub.storage.misc, {:hotswap_state, child_id})

        # Dispatch hook to signal handover delivery complete
        HookManager.dispatch_hook(
          hub.storage.hook,
          Hook.hotswap_handover_delivered(),
          {child_id, node_pids}
        )
    end

    :ok
  end

  @doc """
  Options:
  - `:declare_behaviour` - When `true` (default), declares the `ProcessHub.Behaviour.Handover`
    behaviour and provides default implementations. Set to `false` when using both HotSwap
    and ColdSwap macros in the same module to avoid duplicate declarations.
  """
  defmacro __using__(opts) do
    declare_behaviour = Keyword.get(opts, :declare_behaviour, true)

    behaviour_ast =
      if declare_behaviour do
        quote do
          @behaviour ProcessHub.Behaviour.Handover

          @impl ProcessHub.Behaviour.Handover
          def prepare_handover_state(state), do: state

          @impl ProcessHub.Behaviour.Handover
          def alter_handover_state(_current_state, handover_state), do: handover_state

          defoverridable prepare_handover_state: 1, alter_handover_state: 2
        end
      else
        quote do
        end
      end

    handlers_ast =
      quote do
        @doc false
        def handle_info({:process_hub, :query_hot_handover_state, receiver, child_id}, state) do
          prepared_state = prepare_handover_state(state)
          send(receiver, {:process_hub, :hotswap_state, child_id, prepared_state})
          {:noreply, state}
        end

        @doc false
        def handle_info({:process_hub, :hotswap_handover, _child_id, handover_state}, state) do
          {:noreply, alter_handover_state(state, handover_state)}
        end
      end

    quote do
      unquote(behaviour_ast)
      unquote(handlers_ast)
    end
  end

  # Graceful shutdown handlers

  @doc false
  def handle_shutdown(%__MODULE__{handover: true, state_query_timeout: timeout} = _struct, hub) do
    # Make sure there are other nodes in the cluster left.
    if Cluster.nodes(hub.storage.misc) |> length() > 0 do
      ProcessRegistry.local_data(hub.hub_id)
      |> query_states_for_shutdown(timeout)
      |> send_states_to_target_nodes(hub)
    end

    :ok
  end

  def handle_shutdown(_struct, _hub), do: :ok

  @doc false
  def handle_process_startups(%__MODULE__{handover: true} = _struct, hub, cpids) do
    state_data = Storage.get(hub.storage.misc, StorageKey.msk()) || []

    Enum.each(cpids, fn %{cid: cid, pid: pid} ->
      pstate = Enum.find(state_data, fn {child_id, _} -> child_id === cid end)

      if is_tuple(pstate) do
        send(pid, {:process_hub, :hotswap_handover, cid, pstate |> elem(1)})
      end
    end)

    # Clean up after delivery
    rem_states(Enum.map(state_data, fn {cid, _} -> cid end), hub.storage.misc)
  end

  def handle_process_startups(_struct, _hub, _pids), do: nil

  @doc false
  def handle_storage_update(hub, data) do
    old_value = Storage.get(hub.storage.misc, StorageKey.msk())

    new_value =
      case old_value do
        nil -> data
        _ -> data ++ old_value
      end

    Storage.insert(hub.storage.misc, StorageKey.msk(), new_value, ttl: @graceful_shutdown_ttl)
  end

  # Private helpers for graceful shutdown

  defp query_states_for_shutdown(local_data, timeout) do
    local_node = node()
    self_pid = self()

    # Send query messages to all local processes
    Enum.each(local_data, fn {child_id, {_cs, cn, _m}} ->
      local_pid = Keyword.get(cn, local_node)

      if is_pid(local_pid) do
        send(local_pid, {:process_hub, :query_hot_handover_state, self_pid, child_id})
      end
    end)

    # Collect responses
    states =
      Enum.map(local_data, fn _x ->
        receive do
          {:process_hub, :hotswap_state, cid, state} ->
            {cid, state}
        after
          timeout ->
            Logger.error("Handover timeout while shutting down the node #{local_node}")
            nil
        end
      end)
      |> Enum.filter(&(&1 != nil))

    {local_data, states}
  end

  defp send_states_to_target_nodes({local_data, states}, hub) do
    dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())

    repl_fact =
      Storage.get(hub.storage.misc, StorageKey.strred())
      |> RedundancyStrategy.replication_factor()

    cids = Enum.map(local_data, &elem(&1, 0))
    cid_node_pairs = DistributionStrategy.belongs_to(dist_strat, hub, cids, repl_fact)

    send_data =
      Enum.reduce(cid_node_pairs, %{}, fn {cid, new_nodes}, acc ->
        case Bag.get_by_key(local_data, cid) do
          nil ->
            acc

          {_, cn, _m} ->
            nodes = Keyword.keys(cn)
            migration_node = Enum.find(new_nodes, fn node -> not Enum.member?(nodes, node) end)

            case migration_node do
              nil ->
                acc

              _ ->
                migr_data =
                  (Enum.find(states, fn {child_id, _} -> child_id === cid end) || {nil, nil})
                  |> elem(1)

                node_data = Map.get(acc, migration_node, [])
                Map.put(acc, migration_node, [{cid, migr_data} | node_data])
            end
        end
      end)

    # Send the data to each node
    Enum.each(send_data, fn {target_node, data} ->
      cluster_nodes = Cluster.nodes(hub.storage.misc)

      if Enum.member?(cluster_nodes, target_node) && Enum.member?(Node.list(), target_node) do
        GenServer.cast(
          {hub.hub_id, target_node},
          {:exec_cast, {__MODULE__, :handle_storage_update, [data]}}
        )
      end
    end)
  end

  defp rem_states(cids, misc_storage) do
    case Storage.get(misc_storage, StorageKey.msk()) do
      nil ->
        :ok

      states ->
        new_states = Enum.reject(states, fn {cid, _} -> Enum.member?(cids, cid) end)

        if new_states == [] do
          Storage.remove(misc_storage, StorageKey.msk())
        else
          Storage.insert(misc_storage, StorageKey.msk(), new_states, ttl: @graceful_shutdown_ttl)
        end
    end
  end

  # Protocol implementation

  defimpl MigrationStrategy, for: ProcessHub.Strategy.Migration.HotSwap do
    @impl true
    def init(%HotSwap{handover: true} = strategy, hub) do
      # Register for registry_pid_inserted hook to detect new processes
      registry_handler = %HookManager{
        id: :mhs_registry_insert,
        m: HotSwap,
        f: :handle_registry_insert,
        a: [strategy, hub, :_],
        p: 100
      }

      HookManager.register_handler(
        hub.storage.hook,
        Hook.registry_pid_inserted(),
        registry_handler
      )

      # Register for graceful shutdown
      shutdown_handler = %HookManager{
        id: :mhs_shutdown,
        m: HotSwap,
        f: :handle_shutdown,
        a: [strategy, hub],
        p: 100
      }

      HookManager.register_handler(
        hub.storage.hook,
        Hook.coordinator_shutdown(),
        shutdown_handler
      )

      # Register for process startups (graceful shutdown handover delivery)
      process_startups_handler = %HookManager{
        id: :mhs_process_startups,
        m: HotSwap,
        f: :handle_process_startups,
        a: [strategy, hub, :_],
        p: 100
      }

      HookManager.register_handler(
        hub.storage.hook,
        Hook.process_startups(),
        process_startups_handler
      )

      strategy
    end

    def init(strategy, _hub), do: strategy

    @impl MigrationStrategy
    def handle_topology_expansion(%HotSwap{} = _struct, _hub, _nodes, handler) do
      # TODO: implement hot swap expansion logic
      # For now, return handler unchanged
      handler
    end

    @impl MigrationStrategy
    def handle_topology_contraction(%HotSwap{} = _struct, _hub, _removed_nodes, handler) do
      # TODO: implement hot swap contraction logic
      # For now, return handler unchanged
      handler
    end

    @impl true
    def handle_migrate(
          %HotSwap{handover: handover, state_ttl: ttl, state_query_timeout: timeout} = _struct,
          hub,
          registry_data,
          nodes,
          replication_factor,
          _sync_strategy
        ) do
      local_node = node()
      dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())

      # Calculate new distribution for all children
      cids = Enum.map(registry_data, fn {cid, _} -> cid end)

      cid_node_pairs =
        if length(cids) > 0 do
          DistributionStrategy.belongs_to(dist_strat, hub, cids, replication_factor)
        else
          []
        end

      # Get currently running local children
      local_pids =
        hub.hub_id
        |> ProcessRegistry.local_children()
        |> Extractor.local_cid_pid_pairs()

      local_child_ids = Map.keys(local_pids)

      # Categorize each child based on whether it should migrate to new nodes
      {to_migrate, to_send_to_nodes, migrated} =
        Enum.reduce(registry_data, {[], %{}, []}, fn {child_id, {cs, node_pids, m}},
                                                     {migrate_acc, send_acc, migrated_acc} ->
          nodes_new = Bag.get_by_key(cid_node_pairs, child_id, [])
          running_locally = Enum.member?(local_child_ids, child_id)
          is_orphaned = Keyword.keys(node_pids) == []

          # Find which new node(s) this child should be assigned to
          target_new_nodes = Enum.filter(nodes, fn n -> Enum.member?(nodes_new, n) end)

          cond do
            # Case 1: Running locally, should move to new node, should NOT stay local
            running_locally and length(target_new_nodes) > 0 and
                not Enum.member?(nodes_new, local_node) ->
              target_node = List.first(target_new_nodes)

              updated_send =
                Map.update(send_acc, target_node, [{cs, m}], fn list -> [{cs, m} | list] end)

              # Track this child for migration (state storage + later termination)
              {[{cs, m} | migrate_acc], updated_send, [{cs, m} | migrated_acc]}

            # Case 2: Orphaned (not running anywhere) and should be on new node
            is_orphaned and length(target_new_nodes) > 0 ->
              target_node = List.first(target_new_nodes)

              updated_send =
                Map.update(send_acc, target_node, [{cs, m}], fn list -> [{cs, m} | list] end)

              {migrate_acc, updated_send, [{cs, m} | migrated_acc]}

            # Case 3: No action needed
            true ->
              {migrate_acc, send_acc, migrated_acc}
          end
        end)

      # If handover enabled, query and store states BEFORE sending start requests
      if handover and length(to_migrate) > 0 do
        query_and_store_states_with_pids(hub, to_migrate, local_pids, ttl, timeout)
      end

      # DO NOT terminate locally - this is the key difference from ColdSwap
      # The hook handler will terminate after delivering state

      # Send start requests to new nodes (fire and forget)
      Enum.each(to_send_to_nodes, fn {_target_node, children_data} ->
        if length(children_data) > 0 do
          # TODO: add the new implementation.
          #  Distributor.children_redist_init(hub, target_node, children_data)
        end
      end)

      # Dispatch migration hook
      if length(migrated) > 0 do
        HookManager.dispatch_hook(
          hub.storage.hook,
          Hook.children_migrated(),
          {nodes, migrated}
        )
      end

      :ok
    end

    defp query_and_store_states_with_pids(hub, children_to_migrate, local_pids, ttl, timeout) do
      self_pid = self()

      # Send query messages to all processes and collect child_ids with their PIDs
      child_id_pids =
        Enum.reduce(children_to_migrate, [], fn {cs, _m}, acc ->
          pid = Map.get(local_pids, cs.id)

          if is_pid(pid) do
            send(pid, {:process_hub, :query_hot_handover_state, self_pid, cs.id})
            [{cs.id, pid} | acc]
          else
            acc
          end
        end)

      child_ids = Enum.map(child_id_pids, fn {cid, _} -> cid end)

      # Collect responses with timeout
      states = collect_states(child_ids, timeout, [])

      # Store collected states with TTL, including the old PID reference
      Enum.each(states, fn {child_id, state} ->
        old_pid =
          Enum.find_value(child_id_pids, fn {cid, pid} ->
            if cid == child_id, do: pid, else: nil
          end)

        Storage.insert(
          hub.storage.misc,
          {:hotswap_state, child_id},
          {state, old_pid},
          ttl: ttl
        )
      end)
    end

    defp collect_states([], _timeout, acc), do: acc

    defp collect_states(remaining_cids, timeout, acc) do
      start_time = System.monotonic_time(:millisecond)

      receive do
        {:process_hub, :hotswap_state, cid, state} ->
          new_remaining = List.delete(remaining_cids, cid)
          elapsed = System.monotonic_time(:millisecond) - start_time
          new_timeout = max(0, timeout - elapsed)
          collect_states(new_remaining, new_timeout, [{cid, state} | acc])
      after
        timeout ->
          # Return what we have, some processes may not respond
          acc
      end
    end
  end
end
