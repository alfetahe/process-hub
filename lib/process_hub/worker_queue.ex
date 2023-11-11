defmodule ProcessHub.WorkerQueue do
  use GenServer

  def start_link(name) do
    GenServer.start_link(__MODULE__, nil, name: name)
  end

  def init(_) do
    {:ok, nil}
  end

  def handle_cast({:handle_work, func}, state) do
    func.()

    {:noreply, state}
  end

  def handle_call({:handle_work, func}, state) do
    {:reply, func.(), state}
  end
end
