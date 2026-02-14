defmodule ProcessHub.Worker.WorkerQueue do
  alias ProcessHub.Request.CrossNodeRequest
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Storage

  use GenServer

  def start_link({hub_id, pname, misc_storage}) do
    GenServer.start_link(__MODULE__, {hub_id, misc_storage}, name: pname)
  end

  @impl true
  def init({hub_id, _misc_storage}) do
    {:ok, %{hub_id: hub_id}}
  end

  @impl true
  def handle_cast({:tracked, message, notify_pid}, state) do
    do_work(message, state)
    send(notify_pid, :work_complete)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:handle_work, func}, state) do
    do_work({:handle_work, func}, state)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:handle_requests, requests, hub}, state) do
    do_work({:handle_requests, requests, hub}, state)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:handle_node_down, arg}, state) do
    do_work({:handle_node_down, arg}, state)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:handle_node_up, arg}, state) do
    do_work({:handle_node_up, arg}, state)

    {:noreply, state}
  end

  @impl true
  def handle_call({:handle_work, func}, _from, state) do
    {:reply, func.(), state}
  end

  defp do_work({:handle_work, func}, _state), do: func.()

  defp do_work({:handle_requests, requests, hub}, _state) do
    Task.async_stream(requests, &CrossNodeRequest.handle(&1, hub),
      timeout: Storage.get(hub.storage.misc, StorageKey.cnrt()) || 5000,
      ordered: false,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  defp do_work({:handle_node_down, arg}, _state), do: Cluster.handle_node_down(arg)

  defp do_work({:handle_node_up, arg}, _state), do: Cluster.handle_node_up(arg)
end
