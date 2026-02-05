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
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Utility.Extractor
  alias ProcessHub.Request.Handler.StartChildrenRequest
  alias ProcessHub.Request.Handler.StartChildrenRequest.PostStartData
  alias ProcessHub.Request.PostAction
  alias ProcessHub.Service.Dispatcher

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
    # Build child_id -> pid mapping for successfully started children
    started_pids =
      results
      |> Enum.filter(&match?({:ok, _}, &1.result))
      |> Enum.map(fn %PostStartData{cid: cid, pid: pid} -> {cid, pid} end)
      |> Map.new()

    # Filter to requested child_ids that were actually started
    valid_cid_pids =
      child_ids
      |> Enum.filter(&Map.has_key?(started_pids, &1))
      |> Enum.map(&{&1, Map.get(started_pids, &1)})

    if valid_cid_pids != [] do
      send(
        {hub.hub_id, originating_node},
        {:post_action_callback, __MODULE__, :deliver_handover_states, [node(), valid_cid_pids]}
      )
    end

    :ok
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

  defimpl MigrationStrategy, for: ProcessHub.Strategy.Migration.ColdSwap do
    alias ProcessHub.Strategy.Migration.ColdSwap

    @impl true
    def init(strategy, _hub), do: strategy

    @impl MigrationStrategy
    def handle_topology_expansion(
          %ColdSwap{handover: handover, state_ttl: ttl, state_query_timeout: timeout} = _struct,
          hub,
          nodes,
          handler
        ) do
      local_node = node()

      # Get all registry entries that belong to the current node + entries
      # which do not belong to any node.
      migration_candidates = Extractor.local_and_empty_children(hub.hub_id)

      # Get all cids.
      cids = Enum.map(migration_candidates, fn {cid, _} -> cid end)

      # Calculate belonging nodes for all candidates.
      # Prepare the calculated cid -> nodes map.
      # This acts as a source of truth for where each child should be.
      cid_node_pairs =
        if length(cids) > 0 do
          DistributionStrategy.belongs_to(
            handler.dist_strat,
            hub,
            cids,
            RedundancyStrategy.replication_factor(handler.redun_strat)
          )
        else
          %{}
        end

      # Populate calculated_cids in handler for future reference to
      # avoid recalculation.
      handler = Map.put(handler, :calculated_cids, cid_node_pairs)

      processable =
        Enum.reduce(migration_candidates, %{stop_local: [], forward_to: []}, fn {child_id,
                                                                                 {cspec,
                                                                                  node_pids, meta}},
                                                                                acc ->
          curr_nodes = Keyword.keys(node_pids)
          calculated_nodes = Map.get(cid_node_pairs, child_id, [])

          # Determine if migration needed.
          # First check if calculated nodes differ from current nodes.
          if Enum.sort(curr_nodes) != Enum.sort(calculated_nodes) do
            # Update forward_to list conditionally.
            forward_list = Map.get(acc, :forward_to)

            new_forward_list =
              case eligible_for_sending?(curr_nodes, calculated_nodes, local_node) do
                # Local node should send start request to new nodes.
                true ->
                  new_nodes = find_new_nodes(curr_nodes, calculated_nodes)
                  [{cspec, meta, new_nodes} | forward_list]

                # Local node should not forward child.
                false ->
                  forward_list
              end

            case Enum.member?(calculated_nodes, local_node) do
              # Local node is still a target, conditionally forward.
              true ->
                Map.put(acc, :forward_to, new_forward_list)

              # Local node is no longer a target, mark for stopping and conditionally forward.
              false ->
                acc
                |> Map.put(:stop_local, [child_id | Map.get(acc, :stop_local)])
                |> Map.put(:forward_to, new_forward_list)
            end
          else
            acc
          end
        end)

      %{stop_local: to_stop_locally, forward_to: to_send_to_nodes} = processable

      # Execute: Stop children locally.
      if length(to_stop_locally) > 0 do
        # If handover enabled, query and store states before termination
        if handover do
          local_pids = Extractor.local_cid_pid_pairs(migration_candidates)

          query_and_store_states(hub, to_stop_locally, local_pids, ttl, timeout)
        end

        # Locally terminate children and propagate termination across cluster.
        Distributor.children_terminate(hub, to_stop_locally, handler.sync_strat)
      end

      migrated = Enum.map(to_send_to_nodes, fn {cspec, _meta, _target_nodes} -> cspec end)

      # Prepare item to send and group by target node.
      to_send_to_nodes =
        Enum.reduce(to_send_to_nodes, %{}, fn {cspec, meta, target_nodes}, acc ->
          Enum.reduce(target_nodes, acc, fn target_node, inner_acc ->
            Map.update(inner_acc, target_node, [{cspec, meta}], fn list ->
              [{cspec, meta} | list]
            end)
          end)
        end)

      # Execute: Send start requests to new nodes (fire and forget)
      node_start_requests = create_migration_requests(hub, to_send_to_nodes, handover)

      if length(node_start_requests) > 0 do
        Dispatcher.children_start(hub, node_start_requests)
      end

      # Dispatch migration hook
      if length(migrated) > 0 do
        HookManager.dispatch_hook(
          hub.storage.hook,
          Hook.children_migrated(),
          {nodes, migrated}
        )
      end

      handler
    end

    @impl MigrationStrategy
    def handle_topology_contraction(%ColdSwap{} = _struct, hub, _removed_nodes, handler) do
      local_node = node()

      # Use pre-calculated cid_node_map from handler to avoid recalculating hash ring.
      cid_node_map = Map.get(handler, :calculated_cids, %{})

      registry_data = ProcessRegistry.dump(hub.hub_id)

      # Find children that should be local but aren't
      children_to_start =
        Enum.reduce(registry_data, [], fn {child_id, {cspec, node_pids, meta}}, acc ->
          nodes_orig = Keyword.keys(node_pids)
          nodes_new = Map.get(cid_node_map, child_id, [])

          if Enum.member?(nodes_new, local_node) and not Enum.member?(nodes_orig, local_node) do
            [{cspec, meta} | acc]
          else
            acc
          end
        end)

      if children_to_start != [] do
        grouped = %{local_node => children_to_start}
        requests = create_contraction_requests(hub, grouped, local_node)
        Dispatcher.children_start(hub, requests)
      end

      handler
    end

    defp create_contraction_requests(hub, grouped, _local_node) do
      Enum.flat_map(grouped, fn {_node, children} ->
        if children != [] do
          [StartChildrenRequest.for_contraction(hub, children)]
        else
          []
        end
      end)
    end

    defp find_new_nodes(old_nodes, new_nodes) do
      Enum.filter(new_nodes, fn n -> !Enum.member?(old_nodes, n) end)
    end

    defp find_existing_nodes(old_nodes, new_nodes) do
      Enum.filter(new_nodes, fn n -> Enum.member?(old_nodes, n) end)
    end

    defp eligible_for_sending?(registry_nodes, calculated_nodes, local_node) do
      cond do
        # Old nodes list is empty, meaning this is a first-time assignment.
        registry_nodes == [] ->
          true

        # New nodes contains only one node, meaning there are no other nodes
        # that can send the info, so send it.
        length(calculated_nodes) === 1 ->
          true

        # Local node is the first among the existing nodes that are still targets,
        # so it takes the responsibility to send the start request to the new nodes.
        find_existing_nodes(registry_nodes, calculated_nodes)
        |> List.first() == local_node ->
          true

        # No overlap between old and new nodes - first OLD node takes responsibility.
        # This happens when all target nodes are different from current nodes.
        find_existing_nodes(registry_nodes, calculated_nodes) == [] and
            List.first(Enum.sort(registry_nodes)) == local_node ->
          true

        # Otherwise, do not send.
        true ->
          false
      end
    end

    defp query_and_store_states(hub, children_to_stop, local_pids, ttl, timeout) do
      self_pid = self()

      # Send query messages to all processes and collect child_ids
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

    defp create_migration_requests(hub, to_send_to_nodes, handover) do
      Enum.flat_map(to_send_to_nodes, fn {target_node, children_data} ->
        if children_data != [] do
          opts =
            if handover do
              child_ids = Enum.map(children_data, fn {cspec, _meta} -> cspec.id end)

              [
                post_action:
                  PostAction.new(ColdSwap, :handle_post_action_state_fetch, [node(), child_ids])
              ]
            else
              []
            end

          [StartChildrenRequest.for_migration(hub, target_node, children_data, opts)]
        else
          []
        end
      end)
    end
  end
end
