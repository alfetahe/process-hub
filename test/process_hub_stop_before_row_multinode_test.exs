defmodule Test.ProcessHubStopBeforeRowMultiNodeTest do
  @moduledoc """
  A stop issued on a member whose registry copy has not yet received the
  row of a child that another member started still stops the child.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Service.ProcessRegistry
  alias Test.Helper.Bootstrap
  alias Test.Helper.Common
  alias Test.Helper.TestNode

  @moduletag :multinode

  setup_all do
    peers = TestNode.start_nodes(2, prefix: "stop_before_row_mn")
    Enum.each(peers, fn {_name, pid} -> :erlang.unlink(pid) end)
    on_exit(fn -> Enum.each(peers, fn {_name, pid} -> :peer.stop(pid) end) end)

    [{b, _}, {c, _}] = peers
    {:ok, %{b: b, c: c}}
  end

  setup do
    {:ok, hub_id: :"stop_before_row_mn_#{System.unique_integer([:positive])}"}
  end

  test "a stop from a member whose copy lacks the row stops the child",
       %{hub_id: hub_id, b: b, c: c} do
    cid = :stop_before_row_child
    on_c = %{cid => [c]}
    # This node's placement cannot name c, as a strategy that places by the
    # start's options or by load cannot on a node that did not see the start.
    Bootstrap.start_placed_hubs(hub_id, %{node() => %{}, b => on_c, c => on_c})

    # Started from b, so neither the row nor a start in flight is known here.
    :erpc.call(b, ProcessHub, :start_child, [hub_id, child_spec(cid), []])

    assert Common.eventually(fn ->
             match?({_, [{^c, _}]}, ProcessRegistry.lookup(hub_id, cid))
           end)

    {_, [{^c, pid}]} = ProcessRegistry.lookup(hub_id, cid)

    # This node's copy as it is before the propagated row arrives.
    ProcessRegistry.delete(hub_id, cid)

    result =
      ProcessHub.stop_child(hub_id, cid, awaitable: true, timeout: 5000)
      |> ProcessHub.Future.await()

    assert %ProcessHub.StopResult{status: :ok, stopped: [{^cid, [^c]}], errors: []} = result
    refute :erpc.call(c, Process, :alive?, [pid])
  end

  test "a stop for a child no member runs answers not found", %{hub_id: hub_id, b: b, c: c} do
    Bootstrap.start_placed_hubs(hub_id, %{node() => %{}, b => %{}, c => %{}})

    result =
      ProcessHub.stop_child(hub_id, :never_started, awaitable: true, timeout: 5000)
      |> ProcessHub.Future.await()

    assert %ProcessHub.StopResult{
             status: :error,
             stopped: [],
             errors: [never_started: {:error, :not_found}]
           } = result
  end

  defp child_spec(cid), do: %{id: cid, start: {Test.Helper.TestServer, :start_link, [%{}]}}
end
