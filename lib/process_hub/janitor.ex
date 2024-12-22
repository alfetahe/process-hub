defmodule ProcessHub.Janitor do
  alias ProcessHub.Utility.Name
  alias ProcessHub.Service.Storage

  use GenServer

  def start_link({hub_id, purge_interval}) do
    GenServer.start_link(__MODULE__, {hub_id, purge_interval}, name: Name.janitor(hub_id))
  end

  @impl true
  def init({hub_id, purge_interval}) do
    schedule_cleanup(purge_interval)

    {:ok, %{hub_id: hub_id, purge_interval: purge_interval}}
  end

  @impl true
  def handle_info(:ttl_cleanup, state) do
    purge_cache(state.hub_id)
    schedule_cleanup(state.purge_interval)

    {:noreply, state}
  end

  defp schedule_cleanup(purge_interval) do
    Process.send_after(self(), :ttl_cleanup, purge_interval)
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

      [cache_key, ttl_expire] ->
        if curr_timestamp > ttl_expire do
          Storage.remove(local_storage, cache_key)
        end
    end)
  end
end
