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
  4. When new processes start on the target node, the post-action callback
     notifies the originating node
  5. Originating node delivers stored state and terminates old local process

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

  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Strategy.Migration.SwapMigration
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.Storage
  alias ProcessHub.Strategy.Migration.HotSwap
  alias ProcessHub.Utility.Extractor
  alias ProcessHub.Request.Handler.StartChildrenRequest.PostStartData
  alias ProcessHub.Request.PostAction

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

  @doc """
  Options:
  - `:declare_behaviour` - When `true` (default), declares the `ProcessHub.Strategy.Migration.HandoverBehaviour`
    behaviour and provides default implementations. Set to `false` when using both HotSwap
    and ColdSwap macros in the same module to avoid duplicate declarations.
  """
  defmacro __using__(opts) do
    declare_behaviour = Keyword.get(opts, :declare_behaviour, true)

    behaviour_ast =
      if declare_behaviour do
        quote do
          @behaviour ProcessHub.Strategy.Migration.HandoverBehaviour

          @impl ProcessHub.Strategy.Migration.HandoverBehaviour
          def prepare_handover_state(state), do: state

          @impl ProcessHub.Strategy.Migration.HandoverBehaviour
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

  # Post-action and callback functions

  @doc """
  Post-action callback executed on the target node after children are started.

  Filters successfully started children and sends a callback message to the
  originating node to complete the migration (deliver state + terminate old).
  """
  @spec handle_post_action_migrate_complete(
          ProcessHub.Hub.t(),
          [PostStartData.t()],
          node(),
          [ProcessHub.child_id()]
        ) :: :ok
  def handle_post_action_migrate_complete(hub, results, originating_node, child_ids) do
    SwapMigration.notify_originating_node(
      hub,
      results,
      originating_node,
      child_ids,
      __MODULE__,
      :complete_migration
    )
  end

  @doc """
  Callback executed on the originating node to complete migration.

  Called via generic `:post_action_callback` message from the target node.
  Delivers stored handover states (if any) to new processes, then terminates
  old local processes.
  """
  @spec complete_migration(ProcessHub.Hub.t(), node(), [{ProcessHub.child_id(), pid()}]) :: :ok
  def complete_migration(hub, target_node, cid_pids) do
    child_ids = Enum.map(cid_pids, fn {cid, _pid} -> cid end)

    # If handover enabled, deliver stored states to new processes
    delivered_child_ids =
      Enum.reduce(cid_pids, [], fn {child_id, pid}, acc ->
        case Storage.get(hub.storage.misc, {:hotswap_state, child_id}) do
          nil ->
            acc

          {state, _old_pid} ->
            if is_pid(pid), do: send(pid, {:process_hub, :hotswap_handover, child_id, state})
            Storage.remove(hub.storage.misc, {:hotswap_state, child_id})
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

    # Always terminate old local processes after remote start succeeded.
    sync_strat = Storage.get(hub.storage.misc, StorageKey.strsyn())
    Distributor.children_terminate(hub, child_ids, sync_strat)

    :ok
  end

  # Graceful shutdown handlers - delegate to SwapMigration

  @doc false
  def handle_shutdown(%__MODULE__{handover: true, state_query_timeout: timeout} = _struct, hub) do
    SwapMigration.handle_shutdown(
      hub,
      timeout,
      :query_hot_handover_state,
      :hotswap_state,
      __MODULE__,
      "HotSwap"
    )
  end

  def handle_shutdown(_struct, _hub), do: :ok

  @doc false
  def handle_process_startups(%__MODULE__{handover: true} = _struct, hub, %{children: children}) do
    cpids = Enum.map(children, fn %{child_id: cid, pid: pid} -> %{cid: cid, pid: pid} end)
    SwapMigration.handle_process_startups(hub, cpids, StorageKey.msk(), :hotswap_handover)
  end

  def handle_process_startups(_struct, _hub, _data), do: nil

  @doc false
  def handle_storage_update(hub, data) do
    SwapMigration.handle_storage_update(hub, data, StorageKey.msk())
  end

  # Protocol implementation

  defimpl MigrationStrategy, for: ProcessHub.Strategy.Migration.HotSwap do
    @impl true
    def init(%HotSwap{handover: true} = strategy, hub) do
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

      # Register for post children start (graceful shutdown handover delivery)
      process_startups_handler = %HookManager{
        id: :mhs_process_startups,
        m: HotSwap,
        f: :handle_process_startups,
        a: [strategy, hub, :_],
        p: 100
      }

      HookManager.register_handler(
        hub.storage.hook,
        Hook.post_children_start(),
        process_startups_handler
      )

      strategy
    end

    def init(strategy, _hub), do: strategy

    @impl MigrationStrategy
    def handle_topology_expansion(
          %HotSwap{handover: handover, state_ttl: ttl, state_query_timeout: timeout} = _struct,
          hub,
          nodes,
          handler
        ) do
      {handler, processable, migration_candidates} =
        SwapMigration.compute_processable(hub, handler)

      %{stop_local: to_stop_locally, forward_to: to_send_to_nodes} = processable

      # HotSwap: query and store states BEFORE sending (if handover), but DO NOT terminate.
      if handover and length(to_stop_locally) > 0 do
        local_pids = Extractor.local_cid_pid_pairs(migration_candidates)
        query_and_store_states_with_pids(hub, to_stop_locally, local_pids, ttl, timeout)
      end

      migrated = Enum.map(to_send_to_nodes, fn {cspec, _meta, _target_nodes} -> cspec end)

      # Group by target node and create requests.
      # HotSwap ALWAYS uses a post-action (even without handover) to terminate
      # old processes after remote start succeeds.
      grouped = SwapMigration.group_children_by_node(to_send_to_nodes)

      requests = create_hotswap_requests(hub, grouped, to_stop_locally)
      SwapMigration.send_start_requests(hub, requests)
      SwapMigration.dispatch_migration_hook(hub, migrated, nodes)

      handler
    end

    @impl MigrationStrategy
    def handle_topology_contraction(%HotSwap{} = _struct, hub, _removed_nodes, handler) do
      SwapMigration.handle_contraction(hub, handler)
    end

    # Creates per-node migration requests with post-action that terminates
    # old processes after remote start succeeds.
    defp create_hotswap_requests(hub, grouped_by_node, to_stop_locally) do
      Enum.flat_map(grouped_by_node, fn {target_node, children_data} ->
        if children_data != [] do
          # Only include child_ids that need to be terminated on the originating node.
          child_ids =
            children_data
            |> Enum.map(fn {cspec, _meta} -> cspec.id end)
            |> Enum.filter(fn cid -> Enum.member?(to_stop_locally, cid) end)

          opts =
            if child_ids != [] do
              [
                post_action:
                  PostAction.new(
                    HotSwap,
                    :handle_post_action_migrate_complete,
                    [node(), child_ids]
                  )
              ]
            else
              []
            end

          [
            ProcessHub.Request.Handler.StartChildrenRequest.for_migration(
              hub,
              target_node,
              children_data,
              opts
            )
          ]
        else
          []
        end
      end)
    end

    defp query_and_store_states_with_pids(hub, children_to_stop, local_pids, ttl, timeout) do
      self_pid = self()

      # Send query messages to all processes and collect child_ids with their PIDs
      child_id_pids =
        Enum.reduce(children_to_stop, [], fn cid, acc ->
          pid = Map.get(local_pids, cid)

          if is_pid(pid) && Process.alive?(pid) do
            send(pid, {:process_hub, :query_hot_handover_state, self_pid, cid})
            [{cid, pid} | acc]
          else
            acc
          end
        end)

      child_ids = Enum.map(child_id_pids, fn {cid, _} -> cid end)

      # Collect responses with timeout
      states = SwapMigration.collect_states(child_ids, timeout, [], :hotswap_state)

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
  end
end
