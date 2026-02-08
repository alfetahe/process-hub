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
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Utility.Extractor
  alias ProcessHub.Request.Handler.StartChildrenRequest
  alias ProcessHub.Request.Handler.StartChildrenRequest.PostStartData
  alias ProcessHub.Request.PostAction

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
  Dispatches `Hook.children_migrated()` if migrated list is non-empty.
  """
  @spec dispatch_migration_hook(ProcessHub.Hub.t(), [ProcessHub.child_spec()], [node()]) :: :ok
  def dispatch_migration_hook(_hub, [], _nodes), do: :ok

  def dispatch_migration_hook(hub, migrated_cspecs, nodes) do
    HookManager.dispatch_hook(
      hub.storage.hook,
      Hook.children_migrated(),
      {nodes, migrated_cspecs}
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
    registry_data = ProcessRegistry.dump(hub.hub_id)

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
