defmodule Test.Helper.SetupHelper do
  use ExUnit.Case

  @doc "Returns `prefix` suffixed with a unique integer, for a per-test hub id."
  def unique_id(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  @doc "Builds the `%ProcessHub{}` settings struct `start_hub!/1` would start."
  def hub_struct(opts), do: struct(ProcessHub, opts)

  @doc """
  Starts a hub from `opts` (any `%ProcessHub{}` field), unlinks it, and registers
  its shutdown. Returns `{hub_id, initializer_pid}`.

  Unlike `setup_base/3` this takes the full settings, so a test can pick a
  registry backend, `:auto_recovery`, hooks, or strategies.
  """
  def start_hub!(opts) do
    hub_id = Keyword.fetch!(opts, :hub_id)
    {:ok, pid} = ProcessHub.Initializer.start_link(struct(ProcessHub, opts))
    :erlang.unlink(pid)
    on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)
    {hub_id, pid}
  end

  @doc "Stops the hub, waits for it to go down, and starts it again from `opts`."
  def restart_hub!(hub_id, pid, opts) do
    ref = Process.monitor(pid)
    ProcessHub.Initializer.stop(hub_id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    start_hub!(opts)
  end

  def setup_base(context, hub_id, extra_exits \\ []) do
    case ProcessHub.Initializer.start_link(%ProcessHub{hub_id: hub_id}) do
      {:ok, pid} -> :erlang.unlink(pid)
      {:error, error} -> throw(error)
    end

    hub = ProcessHub.Coordinator.get_hub(hub_id)

    on_exit(:stop_hub, fn ->
      ProcessHub.Initializer.stop(hub_id)
    end)

    Enum.each(extra_exits, fn exit_fun ->
      on_exit(fn -> exit_fun.() end)
    end)

    context
    |> Map.put(:hub_id, hub_id)
    |> Map.put(:hub, hub)
  end
end
