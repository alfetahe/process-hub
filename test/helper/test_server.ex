defmodule Test.Helper.TestServer do
  use GenServer

  def test() do
    :test_ok
  end

  def start_link(args) do
    name = Map.get(args, :name, __MODULE__)
    GenServer.start_link(__MODULE__, args, name: name)
  end

  def init(args) do
    {:ok, args}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:get_value, key}, _from, state) do
    {:reply, Map.get(state, key, nil), state}
  end

  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_info({:set_value, key, value}, state) do
    {:noreply, Map.put(state, key, value)}
  end

  def handle_info({:process_hub, :redundancy_signal, mode}, state) do
    # IO.puts("redundancy_signal: #{inspect(mode)}")

    {:noreply, Map.put(state, :redun_mode, mode)}
  end

  def handle_info({:process_hub, :handover_start, startup_resp, from}, state) do
    case startup_resp do
      {:ok, pid} ->
        Process.send(pid, {:process_hub, :handover, state}, [])
        Process.send(from, {:process_hub, :retention_handled}, [])

      error ->
        IO.puts("Handover failed: #{inspect(error)}")
    end

    {:noreply, state}
  end

  def handle_info({:process_hub, :handover, handover_state}, _state) do
    {:noreply, handover_state}
  end
end
