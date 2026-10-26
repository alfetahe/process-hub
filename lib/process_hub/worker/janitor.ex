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

  @typedoc "Re-placement progress per churn placeholder: `{attempts_made, next_attempt_at_ms}`."
  @type replacing() :: %{ProcessHub.child_id() => {non_neg_integer(), integer()}}

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
       purge_interval: purge_interval,
       replacing: %{}
     }}
  end

  @impl true
  def handle_info(:ttl_cleanup, state) do
    purge_expired_cache(state.misc_storage)
    replacing = purge_pending_registry(state.hub_id, state.replacing)
    schedule_cleanup(state.purge_interval)

    {:noreply, %{state | replacing: replacing}}
  end

  defp schedule_cleanup(purge_interval) do
    Process.send_after(self(), :ttl_cleanup, purge_interval)
  end

  @doc """
  Purges expired TTL cache entries from the given storage table.

  Scans for 3-tuple entries `{key, value, expire_timestamp}` and removes
  any where the timestamp has passed.
  """
  @spec purge_expired_cache(:ets.tid()) :: :ok
  def purge_expired_cache(misc_storage) do
    # Match only items with TTL.
    ttl_items = :ets.match(misc_storage, {:"$1", :_, :"$2"})
    curr_timestamp = now_ms()

    Enum.each(ttl_items, fn
      nil ->
        nil

      [] ->
        []

      [cache_key, ttl_expire] ->
        if curr_timestamp > ttl_expire do
          Storage.remove(misc_storage, cache_key)
        end
    end)

    :ok
  end

  @doc """
  Handles the expired TTL rows of the registry table (see the moduledoc).

  Takes the re-placement progress returned by the previous call and returns
  the progress to pass to the next one.
  """
  @spec purge_pending_registry(ProcessHub.hub_id(), replacing()) :: replacing()
  def purge_pending_registry(hub_id, replacing \\ %{}) do
    now = now_ms()

    {placeholders, removable} =
      hub_id
      |> Storage.match({:"$1", :"$2", :"$3"})
      |> Enum.flat_map(fn
        {child_id, {%{} = child_spec, _nodes, %{} = metadata}, expire}
        when is_integer(expire) and now > expire ->
          [{child_id, child_spec, metadata}]

        _ ->
          []
      end)
      |> Enum.split_with(&replaceable?/1)

    Enum.each(removable, &remove_expired(hub_id, &1, :reconcile))
    replace_placeholders(hub_id, placeholders, replacing, now)
  end

  defp replaceable?({_child_id, _child_spec, metadata}) do
    not Map.has_key?(metadata, :target_nodes) and not Row.durable?(metadata)
  end

  defp replace_placeholders(_hub_id, [], _replacing, _now), do: %{}

  defp replace_placeholders(hub_id, placeholders, replacing, now) do
    {due, waiting} =
      Enum.split_with(placeholders, fn {child_id, _, _} ->
        elem(Map.get(replacing, child_id, {0, 0}), 1) <= now
      end)

    {spent, attempts} =
      Enum.split_with(due, fn {child_id, _, _} ->
        attempts_made(replacing, child_id) >= @replace_attempts
      end)

    Enum.each(spent, &remove_expired(hub_id, &1, :spent))
    attempted = attempt_replace(Hub.get(hub_id), attempts, replacing, now)
    Map.merge(Map.take(replacing, Enum.map(waiting, &elem(&1, 0))), attempted)
  end

  defp attempts_made(replacing, child_id), do: elem(Map.get(replacing, child_id, {0, 0}), 0)

  # Every node holding the placeholder counts the attempt, so each removes its
  # row after the same number of attempts when the one that submits fails.
  defp attempt_replace(_hub, [], _replacing, _now), do: %{}

  defp attempt_replace(hub, placeholders, replacing, now) do
    own = placed_here(hub, placeholders)

    case running_anywhere(hub, own) do
      {:ok, running} ->
        {stale, idle} = Enum.split_with(own, fn {cid, _, _} -> MapSet.member?(running, cid) end)
        Enum.each(stale, &remove_expired(hub.hub_id, &1, :running))
        submit_start(hub, Enum.filter(idle, &still_placeholder?(hub.hub_id, &1)), replacing)
        count_attempts(placeholders -- stale, replacing, now)

      :unknown ->
        Enum.each(own, &log_attempt(&1, replacing, "deferred, a node did not answer"))
        count_attempts(placeholders, replacing, now)
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

  defp count_attempts(placeholders, replacing, now) do
    Map.new(placeholders, fn {child_id, _child_spec, _metadata} ->
      made = attempts_made(replacing, child_id) + 1
      {child_id, {made, now + @replace_backoff_ms * Integer.pow(2, made - 1)}}
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
  defp running_anywhere(_hub, []), do: {:ok, MapSet.new()}

  defp running_anywhere(hub, _placeholders) do
    replies = Distributor.which_children_global(hub, timeout: @peer_check_ms)

    if Enum.all?(replies, &match?({node, children} when is_atom(node) and is_list(children), &1)) do
      running =
        for {_node, children} <- replies,
            {child_id, pid, _type, _modules} <- children,
            is_pid(pid),
            into: MapSet.new(),
            do: child_id

      {:ok, running}
    else
      :unknown
    end
  end

  defp submit_start(_hub, [], _replacing), do: :ok

  defp submit_start(hub, placeholders, replacing) do
    Enum.each(placeholders, &log_attempt(&1, replacing, "submitted"))

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

  defp log_attempt({child_id, child_spec, _metadata}, replacing, outcome) do
    LoggerService.notice(
      "Re-placing churn placeholder - child_id: @child_id, module: @module, " <>
        "attempt: @made of @limit, @outcome",
      %{
        "child_id" => child_id,
        "module" => elem(child_spec.start, 0),
        "made" => attempts_made(replacing, child_id) + 1,
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
