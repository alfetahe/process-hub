defmodule Test.ProcessHubLeadershipMultinodeTest do
  @moduledoc """
  Increment 2 — multi-node leadership ergonomics: graceful step-down and
  leadership-change subscription. Uses a real peer BEAM node via `:peer`.

  The tests are leader-agnostic: elector decides which node wins, so we discover
  the elected leader and act on it rather than assuming the local node wins.
  """
  use ExUnit.Case, async: false

  import Test.Helper.LeadershipCluster

  alias Test.Helper.TestNode
  alias ProcessHub.Service.Leadership

  setup do
    # Clean any leftover local leadership before wiring up the cluster.
    Leadership.stop()

    [{peer, peer_pid}] = TestNode.start_nodes(1, prefix: "leadership_mn")
    :erlang.unlink(peer_pid)

    on_exit(fn ->
      Leadership.stop()
      if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
    end)

    %{peer: peer, peer_pid: peer_pid}
  end

  test "graceful step-down elects a successor among the remaining nodes", %{peer: peer} do
    start_leadership_on(node())
    start_leadership_on(peer)

    {leader, other} = elected_leader_and_other(peer)

    # Both nodes agree on the elected leader.
    assert eventually(fn -> leader_on(peer) == {:ok, leader} end)

    # Step down on the leader; the remaining node must take over promptly
    # (no nodedown wait — the node is still up).
    stop_leadership_on(leader)

    assert eventually(fn -> leader_on(other) == {:ok, other} end)
    assert leader_on(leader) == {:error, :leadership_not_started}
  end

  test "subscribers are notified when the leader changes", %{peer: peer} do
    start_leadership_on(node())
    start_leadership_on(peer)

    {leader, other} = elected_leader_and_other(peer)
    assert eventually(fn -> leader_on(other) == {:ok, leader} end)

    # A probe on the future leader (`other`) subscribes there and relays to us.
    :erpc.call(other, Test.Helper.LeadershipProbe, :start, [self()])

    # Initial snapshot: `other` currently sees `leader` as the leader.
    assert_receive {:probe_leadership, %{leader: ^leader, am_i_leader: false}}, 5_000

    # Leader steps down -> `other` becomes leader -> its subscriber is notified.
    stop_leadership_on(leader)

    assert_receive {:probe_leadership, %{leader: ^other, previous: ^leader, am_i_leader: true}},
                   8_000
  end
end
