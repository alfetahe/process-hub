defmodule Test.ProcessHubForwardMultiNodeTest do
  @moduledoc """
  Starts and stops a node forwards because its placement table disagrees with
  the sender's. Each node is given its own table, so the disagreement is
  fixed for the whole test rather than a window.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.ProcessRegistry
  alias Test.Helper.Bootstrap
  alias Test.Helper.Common
  alias Test.Helper.TestNode
  alias Test.Support.RecordingDistribution

  @moduletag :multinode

  setup_all do
    peers = TestNode.start_nodes(2, prefix: "forward_mn")
    Enum.each(peers, fn {_name, pid} -> :erlang.unlink(pid) end)
    on_exit(fn -> Enum.each(peers, fn {_name, pid} -> :peer.stop(pid) end) end)

    [{b, _}, {c, _}] = peers
    {:ok, %{b: b, c: c}}
  end

  setup do
    {:ok, hub_id: :"forward_mn_#{System.unique_integer([:positive])}"}
  end

  test "a forwarded start is answered by the node that ran it", %{hub_id: hub_id, b: b, c: c} do
    cid = :fwd_start_child
    start_hubs(hub_id, %{node() => %{cid => [b]}, b => %{cid => [c]}, c => %{}})

    result = await_start(hub_id, cid)

    assert %ProcessHub.StartResult{status: :ok, started: [{^cid, [{^c, pid}]}], errors: []} =
             result

    assert :erpc.call(c, Process, :alive?, [pid])
  end

  test "a forwarded stop is answered by the node that stopped the child",
       %{hub_id: hub_id, b: b, c: c} do
    cid = :fwd_stop_child
    on_c = %{cid => [c]}
    start_hubs(hub_id, %{node() => on_c, b => on_c, c => on_c})

    assert %ProcessHub.StartResult{started: [{^cid, [{^c, pid}]}]} = await_start(hub_id, cid)

    # This node's row is left pointing at the peer, whose row points at the
    # node that runs the child, so the stop goes to the peer and is forwarded.
    for n <- [node(), b] do
      assert Common.eventually(fn ->
               match?({_, [{^c, ^pid}]}, :erpc.call(n, ProcessRegistry, :lookup, [hub_id, cid]))
             end)
    end

    ProcessRegistry.insert(hub_id, child_spec(cid), [{b, pid}])

    result =
      ProcessHub.stop_child(hub_id, cid, awaitable: true, timeout: 5000)
      |> ProcessHub.Future.await()

    assert %ProcessHub.StopResult{status: :ok, stopped: [{^cid, [^c]}], errors: []} = result
    refute :erpc.call(c, Process, :alive?, [pid])
  end

  test "a stop issued where the child runs, before its row is written, stops it",
       %{hub_id: hub_id, b: b, c: c} do
    cid = :stop_before_row_child
    on_c = %{cid => [c]}
    start_hubs(hub_id, %{node() => on_c, b => on_c, c => on_c})

    hook = %HookManager{
      id: :stop_from_hook,
      m: Common,
      f: :stop_from_hook,
      a: [self(), hub_id, cid, :_]
    }

    :ok =
      :erpc.call(c, ProcessHub, :register_hook_handlers, [
        hub_id,
        Hook.post_children_start(),
        [hook]
      ])

    assert %ProcessHub.StartResult{started: [{^cid, [{^c, pid}]}]} = await_start(hub_id, cid)
    assert_receive {:stop_from_hook, future, nil}, 5000

    assert %ProcessHub.StopResult{status: :ok, stopped: [{^cid, [^c]}], errors: []} =
             ProcessHub.Future.await(future)

    refute :erpc.call(c, Process, :alive?, [pid])
  end

  test "a start two nodes keep forwarding to each other is refused",
       %{hub_id: hub_id, b: b, c: c} do
    cid = :fwd_loop_child
    start_hubs(hub_id, %{node() => %{cid => [b]}, b => %{cid => [c]}, c => %{cid => [b]}})

    assert %ProcessHub.StartResult{status: :error, started: [], errors: [{^cid, :forward_loop}]} =
             await_start(hub_id, cid)

    for n <- [node(), b, c] do
      assert {^n, []} = :erpc.call(n, ProcessHub, :which_children, [hub_id])
    end
  end

  defp await_start(hub_id, cid) do
    ProcessHub.start_child(hub_id, child_spec(cid), awaitable: true, timeout: 5000)
    |> ProcessHub.Future.await()
  end

  defp child_spec(cid), do: %{id: cid, start: {Test.Helper.TestServer, :start_link, [%{}]}}

  defp start_hubs(hub_id, placements) do
    nodes = placements |> Map.keys() |> Enum.sort()

    for {n, placement} <- placements do
      spec = %ProcessHub{
        hub_id: hub_id,
        distribution_strategy: %RecordingDistribution{placement: placement}
      }

      :erpc.call(n, Bootstrap, :start_hub_on_node, [spec, %{}])
    end

    on_exit(fn -> for n <- nodes, do: :erpc.call(n, ProcessHub.Initializer, :stop, [hub_id]) end)

    for n <- nodes do
      assert Common.eventually(
               fn ->
                 Enum.sort(:erpc.call(n, ProcessHub, :nodes, [hub_id, [:include_local]])) == nodes
               end,
               10_000
             )
    end
  end
end
