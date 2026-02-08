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
  alias ProcessHub.Strategy.Migration.SwapMigration
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Storage
  alias ProcessHub.Utility.Extractor
  alias ProcessHub.Request.Handler.StartChildrenRequest.PostStartData
  alias ProcessHub.Request.PostAction

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

  @doc """
  Post-action callback executed on the target node after children are started.

  Sends a generic callback message to the originating node to deliver stored
  handover states to the newly started processes.
  """
  @spec handle_post_action_state_fetch(ProcessHub.Hub.t(), [PostStartData.t()], node(), [
          ProcessHub.child_id()
        ]) :: :ok
  def handle_post_action_state_fetch(hub, results, originating_node, child_ids) do
    SwapMigration.notify_originating_node(
      hub,
      results,
      originating_node,
      child_ids,
      __MODULE__,
      :deliver_handover_states
    )
  end

  @doc """
  Callback executed on the originating node to deliver stored handover states.

  Called via generic `:post_action_callback` message from the target node.
  """
  @spec deliver_handover_states(ProcessHub.Hub.t(), node(), [{ProcessHub.child_id(), pid()}]) ::
          :ok
  def deliver_handover_states(hub, target_node, cid_pids) do
    delivered_child_ids =
      Enum.reduce(cid_pids, [], fn {child_id, pid}, acc ->
        case Storage.get(hub.storage.misc, {:coldswap_state, child_id}) do
          nil ->
            acc

          state ->
            if is_pid(pid), do: send(pid, {:process_hub, :coldswap_handover, child_id, state})
            Storage.remove(hub.storage.misc, {:coldswap_state, child_id})
            [child_id | acc]
        end
      end)

    if delivered_child_ids != [] do
      HookManager.dispatch_hook(
        hub.storage.hook,
        Hook.handover_delivered(),
        %{child_ids: delivered_child_ids, target_node: target_node}
      )
    end

    :ok
  end

  # Graceful shutdown handlers - delegate to SwapMigration

  @doc false
  def handle_shutdown(%__MODULE__{handover: true, state_query_timeout: timeout} = _struct, hub) do
    SwapMigration.handle_shutdown(
      hub,
      timeout,
      :query_cold_handover_state,
      :coldswap_state,
      __MODULE__,
      "ColdSwap"
    )
  end

  def handle_shutdown(_struct, _hub), do: :ok

  @doc false
  def handle_process_startups(%__MODULE__{handover: true} = _struct, hub, cpids) do
    SwapMigration.handle_process_startups(hub, cpids, StorageKey.mcsk(), :coldswap_handover)
  end

  def handle_process_startups(_struct, _hub, _pids), do: nil

  @doc false
  def handle_storage_update(hub, data) do
    SwapMigration.handle_storage_update(hub, data, StorageKey.mcsk())
  end

  defimpl MigrationStrategy, for: ProcessHub.Strategy.Migration.ColdSwap do
    alias ProcessHub.Strategy.Migration.ColdSwap

    @impl true
    def init(%ColdSwap{handover: true} = strategy, hub) do
      # Register for graceful shutdown
      shutdown_handler = %HookManager{
        id: :mcs_shutdown,
        m: ColdSwap,
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
        id: :mcs_process_startups,
        m: ColdSwap,
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
    def handle_topology_expansion(
          %ColdSwap{handover: handover, state_ttl: ttl, state_query_timeout: timeout} = _struct,
          hub,
          nodes,
          handler
        ) do
      {handler, processable, migration_candidates} =
        SwapMigration.compute_processable(hub, handler)

      %{stop_local: to_stop_locally, forward_to: to_send_to_nodes} = processable

      # ColdSwap: terminate local children BEFORE sending start requests.
      if length(to_stop_locally) > 0 do
        if handover do
          local_pids = Extractor.local_cid_pid_pairs(migration_candidates)
          query_and_store_states(hub, to_stop_locally, local_pids, ttl, timeout)
        end

        Distributor.children_terminate(hub, to_stop_locally, handler.sync_strat)
      end

      migrated = Enum.map(to_send_to_nodes, fn {cspec, _meta, _target_nodes} -> cspec end)

      # Group by target node and create/send requests.
      grouped = SwapMigration.group_children_by_node(to_send_to_nodes)

      requests =
        if handover do
          create_handover_requests(hub, grouped)
        else
          SwapMigration.create_migration_requests(hub, grouped, nil)
        end

      SwapMigration.send_start_requests(hub, requests)
      SwapMigration.dispatch_migration_hook(hub, migrated, nodes)

      handler
    end

    @impl MigrationStrategy
    def handle_topology_contraction(%ColdSwap{} = _struct, hub, _removed_nodes, handler) do
      SwapMigration.handle_contraction(hub, handler)
    end

    # Creates per-node migration requests with handover post-actions.
    # Each node gets its own post_action containing only its child_ids.
    defp create_handover_requests(hub, grouped_by_node) do
      Enum.flat_map(grouped_by_node, fn {target_node, children_data} ->
        if children_data != [] do
          child_ids = Enum.map(children_data, fn {cspec, _meta} -> cspec.id end)

          post_action =
            PostAction.new(ColdSwap, :handle_post_action_state_fetch, [node(), child_ids])

          [
            ProcessHub.Request.Handler.StartChildrenRequest.for_migration(
              hub,
              target_node,
              children_data,
              post_action: post_action
            )
          ]
        else
          []
        end
      end)
    end

    defp query_and_store_states(hub, children_to_stop, local_pids, ttl, timeout) do
      self_pid = self()

      child_ids =
        Enum.reduce(children_to_stop, [], fn cid, acc ->
          pid = Map.get(local_pids, cid)

          if is_pid(pid) && Process.alive?(pid) do
            send(pid, {:process_hub, :query_cold_handover_state, self_pid, cid})
            [cid | acc]
          else
            acc
          end
        end)

      states = SwapMigration.collect_states(child_ids, timeout, [], :coldswap_state)

      Enum.each(states, fn {child_id, state} ->
        Storage.insert(
          hub.storage.misc,
          {:coldswap_state, child_id},
          state,
          ttl: ttl
        )
      end)
    end
  end
end
