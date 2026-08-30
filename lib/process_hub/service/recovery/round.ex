defmodule ProcessHub.Service.Recovery.Round do
  @moduledoc """
  One orphan reconcile round: takes the declared list as the candidate set,
  starts the unaccounted remainder, stops undeclared runners, cleans stale
  rows, and resolves duplicate bindings. A parked list yields no starts and no
  stops — a lost list must never be mistaken for "nothing declared".
  """

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.DeclaredChildren
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.LoggerService
  alias ProcessHub.Service.Migration
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.ProcessRegistry.Row
  alias ProcessHub.Service.Storage
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Hub

  @typedoc "Result of one orphan reconcile round."
  @type result() :: %{
          candidates: non_neg_integer(),
          orphans: non_neg_integer(),
          started: non_neg_integer(),
          skipped_pending: non_neg_integer(),
          duplicates: non_neg_integer(),
          stopped_undeclared: non_neg_integer(),
          deferred_undeclared: non_neg_integer(),
          removed_stale: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          reason: :completed | :parked | :draining | :crashed
        }

  @doc """
  Runs one round, converting any crash into a `:crashed` result — the caller
  relies on always receiving a result, whatever happened. A registry or peer
  call that times out exits rather than raising, hence the catch.
  """
  @spec run_safe(Hub.t(), boolean()) :: result()
  def run_safe(hub, first_round?) do
    run(hub, first_round?)
  rescue
    error -> crashed_result(error)
  catch
    kind, reason -> crashed_result({kind, reason})
  end

  defp run(%Hub{} = hub, first_round?) do
    started_at = System.monotonic_time(:millisecond)

    # A draining node must start nothing, and no other node's ring owner can be
    # draining: draining removes the node from every peer's membership before
    # children move, so it never owns a candidate.
    result =
      cond do
        Migration.draining?(hub) -> empty_result(:draining)
        DeclaredChildren.parked?(hub) -> empty_result(:parked)
        true -> run_round(hub, first_round?)
      end

    result = %{result | elapsed_ms: System.monotonic_time(:millisecond) - started_at}

    HookManager.dispatch_hook(hub.storage.hook, Hook.reconcile_round(), %{
      hub_id: hub.hub_id,
      first_round: first_round?,
      measurements: Map.delete(result, :reason)
    })

    result
  end

  defp run_round(hub, first_round?) do
    entries =
      case DeclaredChildren.manifest(hub) do
        %{entries: entries} -> entries
        nil -> %{}
      end

    live = ProcessRegistry.dump(hub.hub_id)
    registered = ProcessRegistry.dump_all(hub.hub_id)

    {orphans, skipped_pending} = orphan_set(hub, entries, live, registered)
    started = start_orphans(hub, orphans, map_size(entries), first_round?)
    {stopped_undeclared, deferred_undeclared} = stop_undeclared(hub, live, entries)
    removed_stale = remove_stale_rows(hub, registered, entries)
    duplicates = resolve_duplicates(hub, live)

    %{
      empty_result(:completed)
      | candidates: map_size(entries),
        orphans: length(orphans),
        started: started,
        skipped_pending: skipped_pending,
        duplicates: duplicates,
        stopped_undeclared: stopped_undeclared,
        deferred_undeclared: deferred_undeclared,
        removed_stale: removed_stale
    }
  end

  # orphans = declared − observed running anywhere − not-yet-confirmed.
  #
  # The two-consecutive-rounds rule applies only to children the live registry
  # still knows about: those are the ones a migration can leave momentarily
  # unbound. A candidate with no live row at all — the whole-cluster restart case —
  # has nothing in flight to wait for and is restored on the first round.
  defp orphan_set(hub, entries, live, registered) do
    unaccounted =
      Enum.reject(entries, fn {child_id, _child_spec} -> Map.has_key?(live, child_id) end)

    {confirmed, deferred} =
      confirm_over_two_rounds(
        hub,
        StorageKey.rop(),
        Enum.map(unaccounted, fn {child_id, _child_spec} -> child_id end),
        &(not Map.has_key?(registered, &1))
      )

    specs = Map.new(unaccounted)
    {Enum.map(confirmed, &Map.fetch!(specs, &1)), length(deferred)}
  end

  # The two-consecutive-rounds rule, shared by the orphans, the undeclared
  # stops and the stale rows: an id is confirmed when the previous round saw
  # it too — or when `immediate?` says it has nothing in flight to wait for —
  # and deferred otherwise; this round's set is stored under `key` for the
  # next one. Answers `{confirmed, deferred}` in the order given.
  defp confirm_over_two_rounds(hub, key, ids, immediate? \\ fn _id -> false end) do
    pending = Storage.get(hub.storage.misc, key) || MapSet.new()
    Storage.insert(hub.storage.misc, key, MapSet.new(ids))
    Enum.split_with(ids, &(immediate?.(&1) or MapSet.member?(pending, &1)))
  end

  # A stop that crashed between list removal and terminate leaves the child
  # running but undeclared; each node stops its own instance. Only rows marked
  # durable are considered — children never declared are not the reconcile's.
  #
  # Two consecutive rounds, like the orphans: a durable start registers its
  # row before its declared entry commits (the entry rides the batch), so one
  # round inside that window sees a live, durable, undeclared child that is
  # merely young. Answers `{stopped, deferred}`.
  defp stop_undeclared(hub, live, entries) do
    local_node = node()

    undeclared =
      for {child_id, {_child_spec, node_pids, metadata}} <- live,
          Row.durable?(metadata),
          not Map.has_key?(entries, child_id),
          Keyword.has_key?(node_pids, local_node),
          do: child_id

    {confirmed, deferred} = confirm_over_two_rounds(hub, StorageKey.rup(), undeclared)

    case confirmed do
      [] ->
        {0, length(deferred)}

      child_ids ->
        LoggerService.warning(
          "Reconcile stopping undeclared running children: @cids",
          %{"cids" => inspect(child_ids)},
          prefix: "Recovery"
        )

        Distributor.children_terminate(hub, child_ids, on_empty: :delete)
        {length(child_ids), length(deferred)}
    end
  end

  # A stale rejoining peer can re-introduce a row for a declared child the
  # cluster stopped. Such a row — marked durable, observed running nowhere,
  # absent from the list — is removed after surviving two consecutive rounds,
  # so a row that is merely mid-rebind is left alone.
  defp remove_stale_rows(hub, registered, entries) do
    stale =
      for {child_id, {_child_spec, [], metadata}} <- registered,
          Row.durable?(metadata),
          not Map.has_key?(entries, child_id),
          do: child_id

    {ripe, _waiting} = confirm_over_two_rounds(hub, StorageKey.rsp(), stale)

    Enum.each(ripe, &ProcessRegistry.delete(hub.hub_id, &1, hook_storage: hub.storage.hook))
    length(ripe)
  end

  defp start_orphans(_hub, [], _candidate_count, _first_round?), do: 0

  defp start_orphans(hub, child_specs, candidate_count, first_round?) do
    if first_round? do
      HookManager.dispatch_hook_blocking(
        hub.storage.hook,
        Hook.pre_recovery_replay(),
        %{hub_id: hub.hub_id, child_count: candidate_count},
        hub.recovery_config.reconcile_interval_ms
      )
    end

    submit_orphans(hub, child_specs, true)
  end

  # `check_existing: true` rejects the whole batch when any child raced into the
  # registry between the difference and the submit; drop the racers and retry once.
  defp submit_orphans(_hub, [], _retry?), do: 0

  defp submit_orphans(hub, child_specs, retry?) do
    opts =
      [
        {:auto_recovery_replay, true},
        {:awaitable, false},
        {:check_existing, true},
        {:disable_logging, true},
        {:durable, true},
        {:init_cids, Enum.map(child_specs, & &1.id)}
      ]
      |> Distributor.default_init_opts()

    case Distributor.compose_start_operation(hub, child_specs, opts) do
      {:ok, _operation} ->
        length(child_specs)

      {:error, {:already_started, child_ids}} when retry? ->
        submit_orphans(hub, Enum.reject(child_specs, &(&1.id in child_ids)), false)

      {:error, reason} ->
        LoggerService.warning(
          "Reconcile could not start @count orphans: @reason",
          %{"count" => Integer.to_string(length(child_specs)), "reason" => inspect(reason)},
          prefix: "Recovery"
        )

        0
    end
  end

  # --- duplicate bindings -----------------------------------------------------

  # Each node resolves only its own instance: the decision is a pure function of
  # the (converged) registry and the ring, so every node reaches the same verdict
  # and exactly the non-keepers act.
  defp resolve_duplicates(hub, live) do
    case Enum.filter(live, fn {_child_id, {_cs, node_pids, _m}} -> length(node_pids) > 1 end) do
      [] -> 0
      multi_bound -> stop_local_duplicates(hub, multi_bound, keeper_map(hub, multi_bound))
    end
  end

  defp stop_local_duplicates(hub, multi_bound, keepers) do
    Enum.reduce(multi_bound, 0, fn {child_id, {_child_spec, node_pids, _metadata}}, acc ->
      observed = Keyword.keys(node_pids)
      kept = Map.fetch!(keepers, child_id)
      stopped_nodes = observed -- kept

      cond do
        stopped_nodes === [] -> acc
        node() not in stopped_nodes -> acc + 1
        true -> stop_duplicate(hub, child_id, observed, kept, stopped_nodes) + acc
      end
    end)
  end

  defp keeper_map(hub, multi_bound) do
    dist_strategy = Storage.get(hub.storage.misc, StorageKey.strdist())
    redun_strategy = Storage.get(hub.storage.misc, StorageKey.strred())
    replication = RedundancyStrategy.replication_factor(redun_strategy)
    child_ids = Enum.map(multi_bound, fn {child_id, _row} -> child_id end)
    assigned = DistributionStrategy.belongs_to(dist_strategy, hub, child_ids, replication)

    Map.new(multi_bound, fn {child_id, {_child_spec, node_pids, _metadata}} ->
      observed = Keyword.keys(node_pids)

      case Enum.filter(observed, &(&1 in Map.get(assigned, child_id, []))) do
        [] -> {child_id, [Enum.min(observed)]}
        owners -> {child_id, owners}
      end
    end)
  end

  defp stop_duplicate(hub, child_id, observed, kept, stopped_nodes) do
    LoggerService.warning(
      "Reconcile: @cid bound on @observed; keeping @kept, stopping local instance",
      %{
        "cid" => inspect(child_id),
        "observed" => inspect(observed),
        "kept" => inspect(kept)
      },
      prefix: "Recovery"
    )

    Distributor.children_terminate(hub, [child_id])

    HookManager.dispatch_hook(hub.storage.hook, Hook.reconcile_duplicate(), %{
      hub_id: hub.hub_id,
      child_id: child_id,
      instance_count: length(observed),
      kept_node: List.first(kept),
      stopped_nodes: stopped_nodes
    })

    1
  end

  defp crashed_result(error) do
    LoggerService.warning(
      "Reconcile round crashed: @error",
      %{"error" => inspect(error)},
      prefix: "Recovery"
    )

    empty_result(:crashed)
  end

  defp empty_result(reason) do
    %{
      candidates: 0,
      orphans: 0,
      started: 0,
      skipped_pending: 0,
      duplicates: 0,
      stopped_undeclared: 0,
      deferred_undeclared: 0,
      removed_stale: 0,
      elapsed_ms: 0,
      reason: reason
    }
  end
end
