defmodule Test.Helper.TestServer do
  use GenServer
  use ProcessHub.Strategy.Migration.HotSwap

  def test() do
    :test_ok
  end

  def start_link(args) do
    name = Map.get(args, :name, __MODULE__)

    valid_genserver_name =
      if is_binary(name) do
        # use this dangerous `&String.to_atom/1` function in tests ONLY!
        String.to_atom(name)
      else
        name
      end

    GenServer.start_link(__MODULE__, args, name: valid_genserver_name)
  end

  def init(args) do
    # Process.flag(:trap_exit, true)

    {:ok, args}
  end

  # def terminate(reason, state) do
  #   :ok
  # end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:get_value, key}, _from, state) do
    {:reply, Map.get(state, key, nil), state}
  end

  def handle_call({:set_value, key, value}, _from, state) do
    {:reply, :ok, Map.put(state, key, value)}
  end

  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_cast({:stop, reason}, _state) do
    {:stop, reason, nil}
  end

  def handle_cast(:fail, _state) do
    {:stop, :err, nil}
  end

  def handle_info({:process_hub, :redundancy_signal, mode}, state) do
    # IO.puts("redundancy_signal: #{inspect(mode)}")

    {:noreply, Map.put(state, :redun_mode, mode)}
  end
end
