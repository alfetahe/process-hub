defmodule Test.Helper.SetupHelper do
  use ExUnit.Case

  def setup_base(context, hub_id) do
    case ProcessHub.Initializer.start_link(%ProcessHub{hub_id: hub_id}) do
      {:ok, pid} -> :erlang.unlink(pid)
      {:error, error} -> throw(error)
    end

    on_exit(:stop_hub, fn ->
      ProcessHub.Initializer.stop(hub_id)
    end)

    Map.put(context, :hub_id, hub_id)
  end
end
