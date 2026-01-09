defmodule ProcessHub.Strategy.Migration.ColdSwap do
  @moduledoc """
  The cold swap migration strategy implements the `ProcessHub.Strategy.Migration.Base` protocol.
  It provides a migration strategy where the local process is terminated before starting it on
  the remote node.

  Cold swap is a safe strategy if we want to ensure that the child process is not
  running on multiple nodes at the same time.

  This is the default strategy for process migration.

  ## State Handover

  When `handover: true` is set, ColdSwap will:
  1. Query state from local processes before termination
  2. Store states in ETS with TTL
  3. Terminate local processes
  4. Send start requests to new nodes
  5. When new processes are registered, deliver stored state via hook

  To use state handover, your GenServer must `use ProcessHub.Strategy.Migration.ColdSwap`:

      defmodule MyServer do
        use GenServer
        use ProcessHub.Strategy.Migration.ColdSwap

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

  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Utility.Extractor
  alias ProcessHub.DistributedSupervisor

  @typedoc """
  The cold swap migration struct.

  Options:
  - `:handover` - Enable state handover before termination (default: false)
  - `:state_ttl` - TTL for stored states in milliseconds (default: 30000)
  - `:state_query_timeout` - Timeout for querying state from dying process (default: 5000)
  """
  @type t() :: %__MODULE__{
          handover: boolean(),
          state_ttl: pos_integer(),
          state_query_timeout: pos_integer()
        }

  defstruct handover: false,
            state_ttl: 30000,
            state_query_timeout: 5000

  @doc """
  Handles registry_pid_inserted hook to deliver stored state to new processes.
  """
  def handle_registry_insert(_strategy, hub, {child_id, node_pids}) do
    case Storage.get(hub.storage.misc, {:coldswap_state, child_id}) do
      nil ->
        :ok

      state ->
        # Send state to new process(es)
        Enum.each(node_pids, fn {_node, pid} ->
          if is_pid(pid) do
            send(pid, {:process_hub, :coldswap_handover, child_id, state})
          end
        end)

        # Cleanup stored state
        Storage.remove(hub.storage.misc, {:coldswap_state, child_id})

        # Dispatch hook to signal handover delivery complete
        HookManager.dispatch_hook(
          hub.storage.hook,
          Hook.coldswap_handover_delivered(),
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
        def handle_info({:process_hub, :query_cold_handover_state, receiver, child_id}, state) do
          prepared_state = prepare_handover_state(state)
          send(receiver, {:process_hub, :coldswap_state, child_id, prepared_state})
          {:noreply, state}
        end

        @doc false
        def handle_info({:process_hub, :coldswap_handover, _child_id, handover_state}, state) do
          {:noreply, alter_handover_state(state, handover_state)}
        end
      end

    quote do
      unquote(behaviour_ast)
      unquote(handlers_ast)
    end
  end

  defimpl MigrationStrategy, for: ProcessHub.Strategy.Migration.ColdSwap do
    alias ProcessHub.Strategy.Migration.ColdSwap

    @impl true
    def init(%ColdSwap{handover: true} = strategy, hub) do
      # Register for registry_pid_inserted hook to detect new processes
      handler = %HookManager{
        id: :mcs_registry_insert,
        m: ColdSwap,
        f: :handle_registry_insert,
        a: [strategy, hub, :_],
        p: 100
      }

      HookManager.register_handler(
        hub.storage.hook,
        Hook.registry_pid_inserted(),
        handler
      )

      strategy
    end

    def init(strategy, _hub), do: strategy

    @impl true
    def handle_migrate(
          %ColdSwap{handover: handover, state_ttl: ttl, state_query_timeout: timeout} = _struct,
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
      {to_stop_locally, to_send_to_nodes, migrated} =
        Enum.reduce(registry_data, {[], %{}, []}, fn {child_id, {cs, node_pids, m}},
                                                     {stop_acc, send_acc, migrated_acc} ->
          nodes_new = Bag.get_by_key(cid_node_pairs, child_id, [])
          running_locally = Enum.member?(local_child_ids, child_id)
          is_orphaned = Keyword.keys(node_pids) == []

          # Find which new node(s) this child should be assigned to
          # (intersection of belongs_to result and newly joined nodes)
          target_new_nodes = Enum.filter(nodes, fn n -> Enum.member?(nodes_new, n) end)

          cond do
            # Case 1: Running locally, should move to new node, should NOT stay local
            running_locally and length(target_new_nodes) > 0 and
                not Enum.member?(nodes_new, local_node) ->
              target_node = List.first(target_new_nodes)

              updated_send =
                Map.update(send_acc, target_node, [{cs, m}], fn list -> [{cs, m} | list] end)

              {[{cs, m} | stop_acc], updated_send, [{cs, m} | migrated_acc]}

            # Case 2: Orphaned (not running anywhere) and should be on new node
            is_orphaned and length(target_new_nodes) > 0 ->
              target_node = List.first(target_new_nodes)

              updated_send =
                Map.update(send_acc, target_node, [{cs, m}], fn list -> [{cs, m} | list] end)

              {stop_acc, updated_send, [{cs, m} | migrated_acc]}

            # Case 3: No action needed
            true ->
              {stop_acc, send_acc, migrated_acc}
          end
        end)

      # If handover enabled, query and store states before termination
      if handover and length(to_stop_locally) > 0 do
        query_and_store_states(hub, to_stop_locally, local_pids, ttl, timeout)
      end

      # Execute: Stop children locally (fire and forget)
      if length(to_stop_locally) > 0 do
        Enum.each(to_stop_locally, fn {cs, _m} ->
          DistributedSupervisor.terminate_child(hub.procs.dist_sup, cs.id)
        end)
      end

      # Execute: Send start requests to new nodes (fire and forget)
      Enum.each(to_send_to_nodes, fn {target_node, children_data} ->
        if length(children_data) > 0 do
          Distributor.children_redist_init(hub, target_node, children_data)
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

    defp query_and_store_states(hub, children_to_stop, local_pids, ttl, timeout) do
      self_pid = self()

      # Send query messages to all processes and collect child_ids
      child_ids =
        Enum.reduce(children_to_stop, [], fn {%{id: cid}, _m}, acc ->
          pid = Map.get(local_pids, cid)

          if is_pid(pid) && Process.alive?(pid) do
            send(pid, {:process_hub, :query_cold_handover_state, self_pid, cid})
            [cid | acc]
          else
            acc
          end
        end)

      # Collect responses with timeout
      states = collect_states(child_ids, timeout, [])

      # Store collected states with TTL
      Enum.each(states, fn {child_id, state} ->
        Storage.insert(
          hub.storage.misc,
          {:coldswap_state, child_id},
          state,
          ttl: ttl
        )
      end)
    end

    defp collect_states([], _timeout, acc), do: acc

    defp collect_states(remaining_cids, timeout, acc) do
      start_time = System.monotonic_time(:millisecond)

      receive do
        {:process_hub, :coldswap_state, cid, state} ->
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
