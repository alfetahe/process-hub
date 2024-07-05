defmodule ProcessHub.Janitor do
  alias ProcessHub.Utility.Name
  alias ProcessHub.Service.Storage

  use GenServer

  @ttl_cleanup_interval 15000

  def start_link(hub_id) do
    GenServer.start_link(__MODULE__, hub_id, name: Name.janitor(hub_id))
  end

  @impl true
  def init(hub_id) do
    schedule_cleanup()

    {:ok, %{hub_id: hub_id}}
  end

  @impl true
  def handle_info(:ttl_cleanup, state) do
    purge_cache(state.hub_id)
    schedule_cleanup()

    {:noreply, state}
  end

  defp schedule_cleanup() do
    Process.send_after(self(), :ttl_cleanup, @ttl_cleanup_interval)
  end

  defp purge_cache(hub_id) do
    local_storage = Name.local_storage(hub_id)

    # Match only items with TTL.
    ttl_items = :ets.match(local_storage, {:"$1", :_, :"$2"})
    curr_timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    Enum.each(ttl_items, fn
      nil ->
        nil

      [] ->
        []

      {cache_key, ttl_expire} ->
        if curr_timestamp > ttl_expire do
          Storage.remove(local_storage, cache_key)
        end
    end)
  end
end
