defmodule Test.Helper.TestServer do
  use GenServer

  # Use both HotSwap and ColdSwap macros for testing.
  # The first one declares the behaviour, the second one skips it to avoid duplicates.
  use ProcessHub.Strategy.Migration.HotSwap
  use ProcessHub.Strategy.Migration.ColdSwap, declare_behaviour: false

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

  def start_link_err(_args) do
    {:error, :start_link_err}
  end

  @impl GenServer
  def init(args) do
    # Process.flag(:trap_exit, true)

    {:ok, args}
  end

  # def terminate(reason, state) do
  #   :ok
  # end

  @impl GenServer
  def handle_call({:exec, func}, _from, state) do
    res = func.()

    {:reply, res, state}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_call({:get_value, key}, _from, state) do
    {:reply, Map.get(state, key, nil), state}
  end

  @impl GenServer
  def handle_call({:set_value, key, value}, _from, state) do
    {:reply, :ok, Map.put(state, key, value)}
  end

  @impl GenServer
  def handle_call({:stop, reason}, _from, state) do
    {:stop, reason, state}
  end

  @impl GenServer
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  @impl GenServer
  def handle_cast({:stop, reason}, state) do
    {:stop, reason, state}
  end

  @impl GenServer
  def handle_cast(:throw, _state) do
    throw("intentional throw")
  end

  @impl GenServer
  def handle_cast(:raise, _state) do
    raise("intentional raise")
  end

  # Redundancy signal handler
  @impl GenServer
  def handle_info({:process_hub, :redundancy_signal, mode}, state) do
    # IO.puts("redundancy_signal: #{inspect(mode)} on node #{node()} for state #{inspect(state)}")

    {:noreply, Map.put(state, :redun_mode, mode)}
  end
end
