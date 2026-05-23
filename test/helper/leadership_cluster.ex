defmodule Test.Helper.LeadershipCluster do
  @moduledoc false
  # Shared helpers for multi-node leadership/oracle tests. Functions run on the
  # test (local) node and use erpc to drive remote peers.

  def start_leadership_on(n) when n === node(), do: ProcessHub.start_leadership()
  def start_leadership_on(n), do: :erpc.call(n, ProcessHub, :start_leadership, [])

  def stop_leadership_on(n) when n === node(), do: ProcessHub.stop_leadership()
  def stop_leadership_on(n), do: :erpc.call(n, ProcessHub, :stop_leadership, [])

  def leader_on(n) when n === node(), do: ProcessHub.leader()
  def leader_on(n), do: :erpc.call(n, ProcessHub, :leader, [])

  @doc "Waits for a stable elected leader and returns `{leader, other}` for a 2-node cluster."
  def elected_leader_and_other(peer) do
    true = eventually(fn -> match?({:ok, l} when l !== :none, leader_on(node())) end)
    {:ok, leader} = leader_on(node())
    other = Enum.find([node(), peer], &(&1 !== leader))
    {leader, other}
  end

  @doc "Polls `fun` until it returns truthy or the timeout elapses; returns the boolean."
  def eventually(fun, timeout \\ 8_000), do: Test.Helper.Common.eventually(fun, timeout)
end
