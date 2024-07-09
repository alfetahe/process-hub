defmodule ProcessHub.WorkerQueue do
  alias ProcessHub.Utility.Name
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Storage

  use GenServer

  def start_link(hub_id) do
    GenServer.start_link(__MODULE__, hub_id, name: Name.worker_queue(hub_id))
  end

  @impl true
  def init(hub_id) do
    handle_static_children(hub_id)

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

  defp handle_static_children(hub_id) do
    static_child_specs = Storage.get(Name.local_storage(hub_id), StorageKey.staticcs())

    if length(static_child_specs) > 0 do
      res =
        ProcessHub.start_children(
          hub_id,
          static_child_specs,
          async_wait: true
        )
        |> ProcessHub.await()

      case res do
        {:ok, _} -> nil
        {:error, _} -> raise RuntimeError, message: "static children startup failed."
      end
    end
  end
end
