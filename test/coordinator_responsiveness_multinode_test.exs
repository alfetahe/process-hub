defmodule Test.CoordinatorResponsivenessMultinodeTest do
  @moduledoc """
  The coordinator keeps answering while a durable command waits on the
  declared-list leader, which only happens across nodes. Single-node cases
  live in `test/coordinator_responsiveness_test.exs`.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Service.DeclaredChildren
  alias Test.Helper.Bootstrap
  alias Test.Helper.Common
  alias Test.Helper.TestNode

  @moduletag :multinode

  setup_all do
    [{peer, peer_pid}] = TestNode.start_nodes(1, prefix: "resp_mn")
    :erlang.unlink(peer_pid)
    on_exit(fn -> if Process.alive?(peer_pid), do: :peer.stop(peer_pid) end)
    {:ok, %{peer: peer}}
  end

  # Everything goes through :erpc, which also works against this node, so the
  # test does not care which node the election made leader.
  defp on(node, m, f, a), do: :erpc.call(node, m, f, a)

  # 2 — a durable start on a follower commits through the leader's coordinator.
  test "a follower keeps answering while its durable start waits on a busy leader",
       %{peer: peer} do
    hub_id = :"resp_durable_#{System.unique_integer([:positive])}"
    nodes = [node(), peer]

    conf = %ProcessHub{
      hub_id: hub_id,
      auto_recovery: [reconcile_grace_ms: 600_000],
      hubs_discover_interval: 300,
      cluster_event_debounce: 0
    }

    Enum.each(nodes, &on(&1, Bootstrap, :start_hub_on_node, [conf, %{}]))

    on_exit(fn ->
      Enum.each(nodes, fn n ->
        try do
          on(n, :sys, :resume, [hub_id])
        catch
          _, _ -> :ok
        end

        on(n, ProcessHub.Initializer, :stop, [hub_id])
      end)
    end)

    for n <- nodes do
      assert Common.eventually(fn ->
               length(on(n, ProcessHub, :nodes, [hub_id, [:include_local]])) === 2
             end)
    end

    leader = DeclaredChildren.leader(ProcessHub.Hub.get(hub_id))
    [follower] = nodes -- [leader]
    leader_coordinator = on(leader, :erlang, :whereis, [hub_id])

    on(leader, :sys, :suspend, [hub_id])

    spec = %{id: :resp_durable_child, start: {Test.Helper.TestServer, :start_link, [%{}]}}
    test_pid = self()

    spawn(fn ->
      send(
        test_pid,
        {:started, on(follower, ProcessHub, :start_child, [hub_id, spec, [durable: true]])}
      )
    end)

    # The follower is inside its precommit once the leader holds its request.
    assert Common.eventually(fn ->
             {:message_queue_len, n} =
               on(leader, :erlang, :process_info, [leader_coordinator, :message_queue_len])

             n > 0
           end)

    assert Common.answers_within?({hub_id, follower}, 1_000)
    refute_received {:started, _}

    # The start is answered once the leader has committed it.
    on(leader, :sys, :resume, [hub_id])
    assert_receive {:started, {:ok, :start_initiated}}, 5_000

    assert [%{id: :resp_durable_child}] =
             on(follower, DeclaredChildren, :declared_children, [hub_id]).children
  end
end
