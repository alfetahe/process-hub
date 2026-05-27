defmodule Test.ProcessHubDebounceSafetyTest do
  @moduledoc """
  Regression: a hub with `:hubs_discover_interval` <= `:cluster_event_debounce`
  used to never cluster — each discovery tick reset the debounce timer,
  starving the batch forever. The bounded max-wait cap on
  `Coordinator.batch_event/3` must force-flush within bounded time so the hub
  clusters regardless of the ratio.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Test.Helper.{Bootstrap, Common, TestNode}

  @hubs [:debounce_safety_hub, :debounce_safety_warn_hub]
  @discover 100
  @debounce 500

  setup do
    [{peer, peer_pid}] = TestNode.start_nodes(1, prefix: "debounce_safety")
    :erlang.unlink(peer_pid)

    on_exit(fn ->
      for id <- @hubs do
        try_stop(fn -> ProcessHub.Initializer.stop(id) end)
        try_stop(fn -> :erpc.call(peer, ProcessHub.Initializer, :stop, [id]) end)
      end

      if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
    end)

    %{peer: peer}
  end

  test "hub still clusters when hubs_discover_interval <= cluster_event_debounce",
       %{peer: peer} do
    id = :debounce_safety_hub
    start_hub_pair(id, peer)
    assert_clustered(id, peer)
  end

  test "suboptimal debounce/discovery config logs a warning and still clusters",
       %{peer: peer} do
    id = :debounce_safety_warn_hub

    log = capture_log(fn -> start_hub_pair(id, peer) end)

    assert log =~ ":cluster_event_debounce"
    assert log =~ ":hubs_discover_interval"
    assert log =~ Atom.to_string(id)
    assert_clustered(id, peer)
  end

  # ---- helpers --------------------------------------------------------------

  defp start_hub_pair(id, peer) do
    hub = %ProcessHub{
      hub_id: id,
      hubs_discover_interval: @discover,
      cluster_event_debounce: @debounce
    }

    {:ok, pid} = ProcessHub.Initializer.start_link(hub)
    :erlang.unlink(pid)

    # Start + unlink in a single erpc call so the supervisor isn't torn down
    # when the erpc temporary worker exits.
    true = :erpc.call(peer, Bootstrap, :start_hub_on_node, [hub, %{}])
  end

  defp assert_clustered(id, peer) do
    expected = Enum.sort([node(), peer])

    assert Common.eventually(
             fn ->
               local = Enum.sort(ProcessHub.nodes(id, [:include_local]))
               remote = Enum.sort(:erpc.call(peer, ProcessHub, :nodes, [id, [:include_local]]))
               local === expected and remote === expected
             end,
             10_000
           )
  end

  defp try_stop(fun) do
    try do
      fun.()
    catch
      _, _ -> :ok
    end
  end
end
