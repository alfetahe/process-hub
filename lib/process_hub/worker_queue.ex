defmodule ProcessHub.WorkerQueue do
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Storage
  alias ProcessHub.Future

  use GenServer

  def start_link({hub_id, pname, misc_storage}) do
    GenServer.start_link(__MODULE__, {hub_id, misc_storage}, name: pname)
  end

  @impl true
  def init({hub_id, misc_storage}) do
    handle_static_children(hub_id, misc_storage)

    {:ok, %{hub_id: hub_id}}
  end

  @impl true
  def handle_cast({:handle_work, func}, state) do
    func.()

    {:noreply, state}
  end

  @impl true
  def handle_call({:handle_work, func}, _from, state) do
    {:reply, func.(), state}
  end

  defp handle_static_children(hub_id, misc_storage) do
    static_child_specs = Storage.get(misc_storage, StorageKey.staticcs())

    if length(static_child_specs) > 0 do
      res =
        ProcessHub.start_children(
          hub_id,
          static_child_specs,
          awaitable: true
        )
        |> Future.await()

      case res.status do
        :ok -> nil
        :error -> raise RuntimeError, message: "static children startup failed."
      end
    end
  end
end
