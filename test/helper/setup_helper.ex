defmodule Test.Helper.SetupHelper do
  use ExUnit.Case

  def setup_base(context, hub_id, extra_exits \\ []) do
    case ProcessHub.Initializer.start_link(%ProcessHub{hub_id: hub_id}) do
      {:ok, pid} -> :erlang.unlink(pid)
      {:error, error} -> throw(error)
    end

    on_exit(:stop_hub, fn ->
      ProcessHub.Initializer.stop(hub_id)
    end)

    Enum.each(extra_exits, fn exit_fun ->
      on_exit(fn -> exit_fun.() end)
    end)

    Map.put(context, :hub_id, hub_id)
  end
end
