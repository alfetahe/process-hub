defmodule ProcessHub.Worker.Janitor do
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.LoggerService

  use GenServer

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

  Scans for 3-tuple entries `{key, value, expire_timestamp}` and removes
  any where the timestamp has passed.
  """
  @spec purge_expired_cache(:ets.tid()) :: :ok
  def purge_expired_cache(misc_storage) do
    # Match only items with TTL.
    ttl_items = :ets.match(misc_storage, {:"$1", :_, :"$2"})
    curr_timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

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
  Purges expired pending entries from the registry table.

  This function scans the registry for entries with TTL (3-tuple format)
  and removes any that have expired. A warning is logged for each expired entry.
  """
  @spec purge_pending_registry(ProcessHub.hub_id()) :: :ok
  def purge_pending_registry(hub_id) do
    # Match items with TTL in registry table (3-tuple format: {key, value, expire})
    ttl_items = Storage.match(hub_id, {:"$1", :"$2", :"$3"})
    curr_timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    Enum.each(ttl_items, fn
      nil ->
        nil

      {} ->
        nil

      {child_id, {child_spec, _nodes, metadata}, ttl_expire} ->
        if curr_timestamp > ttl_expire do
          log_pending_expiry(hub_id, child_id, child_spec, metadata)
          ProcessRegistry.delete(hub_id, child_id)
        end

      _ ->
        nil
    end)

    :ok
  end

  defp log_pending_expiry(_hub_id, child_id, child_spec, metadata) do
    target_nodes = Map.get(metadata, :target_nodes, [])
    forwarded_at = Map.get(metadata, :forwarded_at, 0)

    LoggerService.notice(
      "Pending child entry expired - child_id: @child_id, module: @module, target_nodes: @target_nodes, forwarded_at: @forwarded_at",
      %{
        "child_id" => child_id,
        "module" => child_spec.start |> elem(0),
        "target_nodes" => target_nodes,
        "forwarded_at" => forwarded_at
      }
    )
  end
end
