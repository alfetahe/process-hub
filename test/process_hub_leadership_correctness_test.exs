defmodule Test.ProcessHubLeadershipCorrectnessTest do
  @moduledoc """
  Regression: the leader ProcessHub surfaces must match what the configured
  election strategy chose, on every node, after a peer joins. Pre-fix, a
  joining peer's pre-merge election ran against an unpopulated candidate
  cache, self-elected, and the wrong leader stuck.
  """
  use ExUnit.Case, async: false

  import Test.Helper.LeadershipCluster

  alias :elector_strategy_behaviour, as: ElectorStrategy
  alias Test.Helper.TestNode
  alias ProcessHub.Service.Leadership

  setup do
    Leadership.stop()
    [{peer, peer_pid}] = TestNode.start_nodes(1, prefix: "leadership_correctness")
    :erlang.unlink(peer_pid)

    on_exit(fn ->
      Leadership.stop()
      if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
    end)

    %{peer: peer}
  end

  test "stored leader equals strategy choice on every node after a peer joins", %{peer: peer} do
    start_leadership_on(node())
    start_leadership_on(peer)

    assert eventually(fn ->
             choice = ElectorStrategy.elect()
             leader_on(node()) === {:ok, choice} and leader_on(peer) === {:ok, choice}
           end)

    # `ut_high' must pick the older test node over the freshly-spawned peer.
    assert ElectorStrategy.elect() === node()
  end
end
