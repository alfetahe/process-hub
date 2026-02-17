defmodule ProcessHub.Strategy.Migration.SwapMigration do
  @moduledoc """
  Shared migration logic used by both ColdSwap and HotSwap strategies.

  This module extracts the common patterns for topology expansion and contraction
  so that both strategies can reuse the same core logic while differing only in
  their termination timing and post-action behavior.
  """

  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.LoggerService
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Utility.Extractor
  alias ProcessHub.Request.Handler.StartChildrenRequest
  alias ProcessHub.Request.Handler.StartChildrenRequest.PostStartData
  alias ProcessHub.Request.PostAction

  # TTL for graceful shutdown state storage (longer than regular migration)
  @graceful_shutdown_ttl :timer.seconds(60)

  @doc """
  Computes processable children for migration during topology expansion.

  Gets migration candidates, calculates distribution, populates `handler.calculated_cids`,
  and categorizes children into `%{stop_local: [...], forward_to: [...]}`.

  Returns `{handler, processable, migration_candidates}`.
  """
  @spec compute_processable(ProcessHub.Hub.t(), map()) :: {map(), map(), map()}
  def compute_processable(hub, handler) do
    local_node = node()

    # Get all registry entries that belong to the current node + entries
    # which do not belong to any node.
    migration_candidates = Extractor.local_and_empty_children(hub.hub_id)

    # Get all cids.
    cids = Enum.map(migration_candidates, fn {cid, _} -> cid end)

    # Calculate belonging nodes for all candidates.
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

    # Populate calculated_cids in handler for future reference.
    handler = Map.put(handler, :calculated_cids, cid_node_pairs)

    processable =
      Enum.reduce(migration_candidates, %{stop_local: [], forward_to: []}, fn {child_id,
                                                                               {cspec, node_pids,
                                                                                meta}},
                                                                              acc ->
        curr_nodes = Keyword.keys(node_pids)
        all_calculated_nodes = Map.get(cid_node_pairs, child_id, [])

        # Only handle PRIMARY (index 0) migration.
        # Replication strategy handles replicas (indices 1+).
        primary_node = List.first(all_calculated_nodes)

        # For forwarding decisions, only consider the primary node
        primary_nodes = if primary_node, do: [primary_node], else: []

        # Determine if migration needed.
        if Enum.sort(curr_nodes) != Enum.sort(all_calculated_nodes) do
          forward_list = Map.get(acc, :forward_to)

          new_forward_list =
            case eligible_for_sending?(curr_nodes, primary_nodes, local_node) do
              true ->
                new_nodes = find_new_nodes(curr_nodes, primary_nodes)
                [{cspec, meta, new_nodes} | forward_list]

              false ->
                forward_list
            end

          # Local node should stop if it's no longer in ANY of the calculated nodes.
          case Enum.member?(all_calculated_nodes, local_node) do
            true ->
              Map.put(acc, :forward_to, new_forward_list)

            false ->
              acc
              |> Map.put(:stop_local, [child_id | Map.get(acc, :stop_local)])
              |> Map.put(:forward_to, new_forward_list)
          end
        else
          acc
        end
      end)

    {handler, processable, migration_candidates}
  end

  @doc """
  Groups `[{cspec, meta, target_nodes}]` into `%{node => [{cspec, meta}]}`.
  """
  @spec group_children_by_node([{ProcessHub.child_spec(), map(), [node()]}]) :: %{
          node() => [{ProcessHub.child_spec(), map()}]
        }
  def group_children_by_node(forward_to_list) do
    Enum.reduce(forward_to_list, %{}, fn {cspec, meta, target_nodes}, acc ->
      Enum.reduce(target_nodes, acc, fn target_node, inner_acc ->
        Map.update(inner_acc, target_node, [{cspec, meta}], fn list ->
          [{cspec, meta} | list]
        end)
      end)
    end)
  end

  @doc """
  Creates `StartChildrenRequest.for_migration` for each node group.

  `post_action` is nil or a `PostAction` struct.
  """
  @spec create_migration_requests(
          ProcessHub.Hub.t(),
          %{node() => [{ProcessHub.child_spec(), map()}]},
          PostAction.t() | nil
        ) :: [StartChildrenRequest.t()]
  def create_migration_requests(hub, grouped_by_node, post_action) do
    Enum.flat_map(grouped_by_node, fn {target_node, children_data} ->
      if children_data != [] do
        opts = if post_action, do: [post_action: post_action], else: []
        [StartChildrenRequest.for_migration(hub, target_node, children_data, opts)]
      else
        []
      end
    end)
  end

  @doc """
  Sends start requests via Dispatcher if non-empty.
  """
  @spec send_start_requests(ProcessHub.Hub.t(), [StartChildrenRequest.t()]) :: :ok
  def send_start_requests(_hub, []), do: :ok

  def send_start_requests(hub, requests) do
    Dispatcher.children_start(hub, requests)
  end

  @doc """
  Dispatches `Hook.migration_completed()` if migrated list is non-empty.
  """
  @spec dispatch_migration_hook(ProcessHub.Hub.t(), [ProcessHub.child_spec()], [node()]) :: :ok
  def dispatch_migration_hook(_hub, [], _nodes), do: :ok

  def dispatch_migration_hook(hub, migrated_cspecs, nodes) do
    HookManager.dispatch_hook(
      hub.storage.hook,
      Hook.migration_completed(),
      %{nodes: nodes, child_specs: migrated_cspecs}
    )
  end

  @doc """
  Full contraction logic (identical for both strategies).

  Uses pre-calculated `handler.calculated_cids` to start children locally
  that should now be PRIMARY on the local node.
  """
  @spec handle_contraction(ProcessHub.Hub.t(), map()) :: map()
  def handle_contraction(hub, handler) do
    local_node = node()
    cid_node_map = Map.get(handler, :calculated_cids, %{})
    registry_data = ProcessRegistry.dump_all(hub.hub_id)

    # Find children that should be started locally as PRIMARY.
    children_to_start =
      Enum.reduce(registry_data, [], fn {child_id, {cspec, node_pids, meta}}, acc ->
        nodes_orig = Keyword.keys(node_pids)
        nodes_new = Map.get(cid_node_map, child_id, [])

        primary_node = List.first(nodes_new)

        if primary_node == local_node and not Enum.member?(nodes_orig, local_node) do
          [{cspec, meta} | acc]
        else
          acc
        end
      end)

    if children_to_start != [] do
      requests = [StartChildrenRequest.for_contraction(hub, children_to_start)]
      Dispatcher.children_start(hub, requests)
    end

    handler
  end

  @doc """
  Generic state collection with configurable response message atom.

  ColdSwap uses `:coldswap_state`, HotSwap uses `:hotswap_state`.
  """
  @spec collect_states([ProcessHub.child_id()], non_neg_integer(), list(), atom()) :: list()
  def collect_states([], _timeout, acc, _response_msg_atom), do: acc

  def collect_states(remaining_cids, timeout, acc, response_msg_atom) do
    start_time = System.monotonic_time(:millisecond)

    receive do
      {:process_hub, ^response_msg_atom, cid, state} ->
        new_remaining = List.delete(remaining_cids, cid)
        elapsed = System.monotonic_time(:millisecond) - start_time
        new_timeout = max(0, timeout - elapsed)
        collect_states(new_remaining, new_timeout, [{cid, state} | acc], response_msg_atom)
    after
      timeout ->
        acc
    end
  end

  @doc """
  Shared post-action logic on target node.

  Filters successfully started children, sends callback to originating node.
  """
  @spec notify_originating_node(
          ProcessHub.Hub.t(),
          [PostStartData.t()],
          node(),
          [ProcessHub.child_id()],
          module(),
          atom()
        ) :: :ok
  def notify_originating_node(
        hub,
        results,
        originating_node,
        child_ids,
        callback_mod,
        callback_fun
      ) do
    started_pids =
      results
      |> Enum.filter(&match?({:ok, _}, &1.result))
      |> Enum.map(fn %PostStartData{cid: cid, pid: pid} -> {cid, pid} end)
      |> Map.new()

    valid_cid_pids =
      child_ids
      |> Enum.filter(&Map.has_key?(started_pids, &1))
      |> Enum.map(&{&1, Map.get(started_pids, &1)})

    if valid_cid_pids != [] do
      send(
        {hub.hub_id, originating_node},
        {:post_action_callback, callback_mod, callback_fun, [node(), valid_cid_pids]}
      )
    end

    :ok
  end

  ##############################################################################
  # Graceful shutdown support
  ##############################################################################

  @doc """
  Handles graceful shutdown by querying states from all local processes and
  sending them to target nodes before this node goes down.

  Parameters:
  - `hub` - the hub struct
  - `timeout` - state query timeout in ms
  - `query_msg` - atom to send to processes (e.g. `:query_cold_handover_state`)
  - `response_msg` - atom expected in response (e.g. `:coldswap_state`)
  - `callback_mod` - module containing `handle_storage_update/2` for remote cast
  - `log_prefix` - string for timeout log messages (e.g. `"ColdSwap"`)
  """
  @spec handle_shutdown(
          ProcessHub.Hub.t(),
          non_neg_integer(),
          atom(),
          atom(),
          module(),
          String.t()
        ) ::
          :ok
  def handle_shutdown(hub, timeout, query_msg, response_msg, callback_mod, log_prefix) do
    if Cluster.nodes(hub.storage.misc) |> length() > 0 do
      ProcessRegistry.local_data(hub.hub_id)
      |> query_states_for_shutdown(timeout, query_msg, response_msg, log_prefix)
      |> send_states_to_target_nodes(hub, callback_mod)
    end

    :ok
  end

  @doc """
  Handles delivery of pre-sent shutdown states when processes start on the target node.

  Parameters:
  - `hub` - the hub struct
  - `cpids` - list of `%{cid: child_id, pid: pid}` structs from process_startups hook
  - `storage_key` - ETS key where shutdown states are stored
  - `delivery_msg` - atom for delivery message (e.g. `:coldswap_handover`)
  """
  @spec handle_process_startups(ProcessHub.Hub.t(), list(), atom(), atom()) :: nil
  def handle_process_startups(hub, cpids, storage_key, delivery_msg) do
    state_data = Storage.get(hub.storage.misc, storage_key) || []

    Enum.each(cpids, fn %{cid: cid, pid: pid} ->
      pstate = Enum.find(state_data, fn {child_id, _} -> child_id === cid end)

      if is_tuple(pstate) do
        send(pid, {:process_hub, delivery_msg, cid, elem(pstate, 1)})
      end
    end)

    # Clean up after delivery
    rem_states(Enum.map(state_data, fn {cid, _} -> cid end), hub.storage.misc, storage_key)
  end

  @doc """
  Stores received shutdown state data on the target node.

  Called via `GenServer.cast` from the shutting-down node.
  """
  @spec handle_storage_update(ProcessHub.Hub.t(), list(), atom()) :: :ok
  def handle_storage_update(hub, data, storage_key) do
    old_value = Storage.get(hub.storage.misc, storage_key)

    new_value =
      case old_value do
        nil -> data
        _ -> data ++ old_value
      end

    Storage.insert(hub.storage.misc, storage_key, new_value, ttl: @graceful_shutdown_ttl)
  end

  # Queries states from all local processes during shutdown
  defp query_states_for_shutdown(local_data, timeout, query_msg, response_msg, log_prefix) do
    local_node = node()
    self_pid = self()

    Enum.each(local_data, fn {child_id, {_cs, cn, _m}} ->
      local_pid = Keyword.get(cn, local_node)

      if is_pid(local_pid) do
        send(local_pid, {:process_hub, query_msg, self_pid, child_id})
      end
    end)

    states =
      Enum.map(local_data, fn _x ->
        receive do
          {:process_hub, ^response_msg, cid, state} ->
            {cid, state}
        after
          timeout ->
            LoggerService.error(
              "Handover timeout while shutting down the node @node",
              %{"node" => local_node},
              prefix: log_prefix
            )

            nil
        end
      end)
      |> Enum.filter(&(&1 != nil))

    {local_data, states}
  end

  # Sends collected shutdown states to target nodes
  defp send_states_to_target_nodes({local_data, states}, hub, callback_mod) do
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

    Enum.each(send_data, fn {target_node, data} ->
      cluster_nodes = Cluster.nodes(hub.storage.misc)

      if Enum.member?(cluster_nodes, target_node) && Enum.member?(Node.list(), target_node) do
        GenServer.cast(
          {hub.hub_id, target_node},
          {:exec_cast, {callback_mod, :handle_storage_update, [data]}}
        )
      end
    end)
  end

  # Removes delivered shutdown states from storage
  defp rem_states(cids, misc_storage, storage_key) do
    case Storage.get(misc_storage, storage_key) do
      nil ->
        :ok

      states ->
        new_states = Enum.reject(states, fn {cid, _} -> Enum.member?(cids, cid) end)

        if new_states == [] do
          Storage.remove(misc_storage, storage_key)
        else
          Storage.insert(misc_storage, storage_key, new_states, ttl: @graceful_shutdown_ttl)
        end
    end
  end

  ##############################################################################
  # Helpers
  ##############################################################################

  @doc false
  def find_new_nodes(old_nodes, new_nodes) do
    Enum.filter(new_nodes, fn n -> !Enum.member?(old_nodes, n) end)
  end

  @doc false
  def find_existing_nodes(old_nodes, new_nodes) do
    Enum.filter(new_nodes, fn n -> Enum.member?(old_nodes, n) end)
  end

  @doc false
  def eligible_for_sending?(registry_nodes, calculated_nodes, local_node) do
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
      find_existing_nodes(registry_nodes, calculated_nodes) == [] and
          List.first(Enum.sort(registry_nodes)) == local_node ->
        true

      # Otherwise, do not send.
      true ->
        false
    end
  end
end
