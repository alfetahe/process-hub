defmodule Test.Helper.LeadershipProbe do
  @moduledoc false
  # Peer-side test helper: subscribes to leadership-change notifications on the
  # node where it runs and relays each one to `target` (typically the test
  # process on another node) as `{:probe_leadership, info}`.

  @spec start(pid()) :: pid()
  def start(target) do
    spawn(fn ->
      ProcessHub.Service.Leadership.subscribe()
      loop(target)
    end)
  end

  defp loop(target) do
    receive do
      {:processhub_leadership, info} ->
        send(target, {:probe_leadership, info})
        loop(target)

      _other ->
        loop(target)
    end
  end
end
