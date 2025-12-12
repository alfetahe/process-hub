defmodule ProcessHub.New.Coordinator do
  use GenServer

  # TODO: remove

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(_args) do
    {:ok, %{}}
  end

  def handle_call({:start_children}, _from, state) do
    {:reply, :ok, state}
  end
end
