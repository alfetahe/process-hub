defmodule ProcessHub.Worker.Janitor do
  @moduledoc """
  Purges expired TTL entries from the hub's storage and registry.

  An expired registry row is one of two kinds:

    * a **pending forward**: a start forwarded to another node that never
      registered. It is removed and logged.
    * a **churn placeholder**: the row a move, a duplicate resolution or a
      node-down cleanup leaves when it stops the child's last registered copy,
      kept 30 seconds for the replacement to register. When nothing registered,
      the child runs nowhere although nobody asked to stop it (a user stop
      removes the row instead of leaving a placeholder), so it is re-placed
      through the distribution strategy. Only the node the strategy names first
      submits the start, and only while the hub is not partitioned, every node
      answers that the child is not running, and the row read again just before
      the start is still an unbound placeholder. Attempts are bounded and backed
      off, each one logged, a deferred one too; after the last, the row is
      removed and logged. A durable child's
      placeholder is removed at once: the orphan reconcile restarts it while it
      is declared.
  """

  alias ProcessHub.Hub
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.LoggerService
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.ProcessRegistry.Row
  alias ProcessHub.Service.State
  alias ProcessHub.Service.Storage
  alias ProcessHub.Strategy.Migration.SwapMigration

  use GenServer

  @replace_attempts 5
  @replace_backoff_ms 15_000
  @peer_check_ms 5_000
  # Bounds one tick after a mass expiry; the rest falls due on the next.
  @due_per_tick 10_000

  def start_link({hub_id, pname, misc_storage, purge_interval}) do
    GenServer.start_link(__MODULE__, {hub_id, pname, misc_storage, purge_interval}, name: pname)
  end

  @impl true
  def init({hub_id, pname, misc_storage, purge_interval}) do
    schedule_cleanup(purge_interval)

    {:ok,
     %{
       hub_id: hub_id,
       pname: pname,
       misc_storage: misc_storage,
       purge_interval: purge_interval
     }}
  end

  @impl true
  def handle_info(:ttl_cleanup, state) do
    purge_expired_cache(state.misc_storage)
    purge_pending_registry(state.hub_id)
    schedule_cleanup(state.purge_interval)

    {:noreply, state}
  end

  defp schedule_cleanup(purge_interval) do
    Process.send_after(self(), :ttl_cleanup, purge_interval)
  end

  @doc """
  Purges expired TTL cache entries from the given storage table.

  Removes every 3-tuple entry `{key, value, expire_timestamp}` whose timestamp
  has passed, in one atomic delete, so an entry re-written with a fresh TTL
  meanwhile is kept.
  """
  @spec purge_expired_cache(:ets.tid()) :: :ok
  def purge_expired_cache(misc_storage) do
    now = now_ms()

    :ets.select_delete(misc_storage, [
      {{:_, :_, :"$1"}, [{:is_integer, :"$1"}, {:<, :"$1", now}], [true]}
    ])

    :ok
  end

  @doc """
  Handles the expired TTL rows of the registry table (see the moduledoc).

  Only rows whose key in the hub's expiry index has fallen due are read, each
  by its child id, so the cost follows the rows due, not the registry's size.
  """
  @spec purge_pending_registry(ProcessHub.hub_id()) :: :ok
  def purge_pending_registry(hub_id) do
    now = now_ms()

    case ProcessRegistry.due_expiries(hub_id, now, @due_per_tick) do
      [] -> :ok
      due -> purge_due(hub_id, due_by_child(due), now)
    end
  end

  # A child can hold more than one due key: a re-lease adds its own.
  defp due_by_child(due) do
    Enum.reduce(due, %{}, fn {{_due_at, child_id} = key, made}, acc ->
      Map.update(acc, child_id, {[key], made}, fn {keys, n} -> {[key | keys], max(n, made)} end)
    end)
  end

  defp purge_due(hub_id, due, now) do
    {placeholders, removable} =
      due
      |> Enum.flat_map(fn {child_id, _} -> expired_row(hub_id, child_id, now) end)
      |> Enum.split_with(&replaceable?/1)

    Enum.each(removable, &remove_expired(hub_id, &1, :reconcile))
    counted = replace_placeholders(hub_id, placeholders, due)

    ProcessRegistry.reschedule_expiries(
      hub_id,
      Enum.map(due, fn {child_id, {keys, _made}} ->
        {child_id, keys, next_attempt(Map.get(counted, child_id), now)}
      end)
    )
  end

  # A key is only a hint: the row, read by its key, decides.
  defp expired_row(hub_id, child_id, now) do
    case Storage.match(hub_id, {child_id, :"$1", :"$2"}) do
      [{{%{} = child_spec, _nodes, %{} = metadata}, expire}]
      when is_integer(expire) and now > expire ->
        [{child_id, child_spec, metadata}]

      _ ->
        []
    end
  end

  defp next_attempt(nil, _now), do: nil
  defp next_attempt(made, now), do: {now + @replace_backoff_ms * Integer.pow(2, made - 1), made}

  defp replaceable?({_child_id, _child_spec, metadata}) do
    not Map.has_key?(metadata, :target_nodes) and not Row.durable?(metadata)
  end

  defp replace_placeholders(_hub_id, [], _due), do: %{}

  defp replace_placeholders(hub_id, placeholders, due) do
    {spent, attempts} =
      Enum.split_with(placeholders, fn {child_id, _, _} ->
        attempts_made(due, child_id) >= @replace_attempts
      end)

    Enum.each(spent, &remove_expired(hub_id, &1, :spent))
    attempt_replace(Hub.get(hub_id), attempts, due)
  end

  defp attempts_made(due, child_id), do: elem(Map.fetch!(due, child_id), 1)

  # Every node holding the placeholder counts the attempt, so each removes its
  # row after the same number of attempts when the one that submits fails.
  defp attempt_replace(_hub, [], _due), do: %{}

  defp attempt_replace(hub, placeholders, due) do
    own = placed_here(hub, placeholders)

    case running_anywhere(hub, own) do
      {:ok, running} ->
        {stale, idle} = Enum.split_with(own, &MapSet.member?(running, elem(&1, 0)))
        Enum.each(stale, &remove_expired(hub.hub_id, &1, :running))
        submit_start(hub, Enum.filter(idle, &still_placeholder?(hub.hub_id, &1)), due)
        count_attempts(Enum.reject(placeholders, &MapSet.member?(running, elem(&1, 0))), due)

      :unknown ->
        Enum.each(own, &log_attempt(&1, due, "deferred, a node did not answer"))
        count_attempts(placeholders, due)
    end
  end

  # Read again after the check of the supervisors, which can take seconds: a
  # stop or a registration meanwhile removed the row or bound it.
  defp still_placeholder?(hub_id, {child_id, _child_spec, _metadata}) do
    now = now_ms()

    match?(
      [{expire}] when is_integer(expire) and now > expire,
      Storage.match(hub_id, {child_id, {:_, [], :_}, :"$1"})
    )
  end

  defp count_attempts(placeholders, due) do
    Map.new(placeholders, fn {child_id, _child_spec, _metadata} ->
      {child_id, attempts_made(due, child_id) + 1}
    end)
  end

  # Only the strategy's first node submits, so one start is sent per attempt;
  # a partitioned hub starts nothing, like its node-down redistribution.
  defp placed_here(hub, placeholders) do
    if State.is_partitioned?(hub) do
      []
    else
      owners = SwapMigration.belongs_to(hub, Enum.map(placeholders, &elem(&1, 0)))
      local = node()
      Enum.filter(placeholders, &match?([^local | _], Map.get(owners, elem(&1, 0), [])))
    end
  end

  # A row can miss a registration made elsewhere, so the supervisors decide
  # whether the child runs; a node that does not answer leaves it unknown.
  # Every hub node is asked: a child can run where its strategy does not
  # place it now, and the row names no node.
  defp running_anywhere(_hub, []), do: {:ok, MapSet.new()}

  defp running_anywhere(hub, placeholders) do
    args = [hub.hub_id, Enum.map(placeholders, &elem(&1, 0)), [settle: true]]

    hub.storage.misc
    |> Cluster.nodes([:include_local])
    |> :erpc.multicall(Distributor, :running_children, args, @peer_check_ms)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      {:ok, running}, {:ok, acc} when is_list(running) ->
        {:cont, {:ok, Enum.into(running, acc)}}

      _, _ ->
        {:halt, :unknown}
    end)
  end

  defp submit_start(_hub, [], _due), do: :ok

  defp submit_start(hub, placeholders, due) do
    Enum.each(placeholders, &log_attempt(&1, due, "submitted"))

    opts =
      Distributor.default_init_opts(
        child_metadata:
          Map.new(placeholders, fn {child_id, _child_spec, metadata} ->
            {child_id, Map.delete(metadata, Row.reserved_key())}
          end),
        init_cids: Enum.map(placeholders, &elem(&1, 0))
      )

    case Distributor.compose_start_operation(hub, Enum.map(placeholders, &elem(&1, 1)), opts) do
      {:ok, _operation} ->
        :ok

      {:error, reason} ->
        LoggerService.warning("Re-placing churn placeholders failed: @reason", %{
          "reason" => reason
        })
    end
  end

  defp log_attempt({child_id, child_spec, _metadata}, due, outcome) do
    LoggerService.notice(
      "Re-placing churn placeholder - child_id: @child_id, module: @module, " <>
        "attempt: @made of @limit, @outcome",
      %{
        "child_id" => child_id,
        "module" => elem(child_spec.start, 0),
        "made" => attempts_made(due, child_id) + 1,
        "limit" => @replace_attempts,
        "outcome" => outcome
      }
    )
  end

  # Re-validates expiry inside the registry process before deleting: the match
  # is a dirty read, and a registration may have cleared the TTL since, in which
  # case the guarded delete is a no-op and nothing is logged.
  defp remove_expired(hub_id, {child_id, child_spec, metadata}, outcome) do
    if ProcessRegistry.delete_if_expired(hub_id, child_id) do
      log_expiry(outcome, child_id, child_spec, metadata)
    end
  end

  defp log_expiry(_outcome, child_id, child_spec, %{target_nodes: target_nodes} = metadata) do
    LoggerService.notice(
      "Pending child entry expired - child_id: @child_id, module: @module, target_nodes: @target_nodes, forwarded_at: @forwarded_at",
      %{
        "child_id" => child_id,
        "module" => elem(child_spec.start, 0),
        "target_nodes" => target_nodes,
        "forwarded_at" => Map.get(metadata, :forwarded_at, 0)
      }
    )
  end

  defp log_expiry(outcome, child_id, child_spec, _metadata) do
    LoggerService.notice(
      "Churn placeholder expired - child_id: @child_id, module: @module, outcome: @outcome",
      %{
        "child_id" => child_id,
        "module" => elem(child_spec.start, 0),
        "outcome" => expiry_outcome(outcome)
      }
    )
  end

  defp expiry_outcome(:reconcile), do: "removed; a durable child is restarted by the reconcile"
  defp expiry_outcome(:running), do: "removed; the child runs on another node"

  defp expiry_outcome(:spent),
    do:
      "removed; not re-placed after #{@replace_attempts} attempts, each logged by the node that places it"

  defp now_ms, do: DateTime.utc_now() |> DateTime.to_unix(:millisecond)
end
