defmodule Test.ProcessHubOracleMultinodeTest do
  @moduledoc """
  Increment 3 — multi-node oracle behaviour: exactly one oracle on the leader,
  failover with directory rebuild from re-announcement, and cross-node
  de-duplication of coordination work.
  """
  use ExUnit.Case, async: false

  import Test.Helper.LeadershipCluster

  alias Test.Helper.TestNode
  alias ProcessHub.Service.Leadership
  alias ProcessHub.Service.Oracle

  setup do
    Leadership.stop()

    [{peer, peer_pid}] = TestNode.start_nodes(1, prefix: "oracle_mn")
    :erlang.unlink(peer_pid)

    on_exit(fn ->
      Leadership.stop()
      if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
    end)

    %{peer: peer, peer_pid: peer_pid}
  end

  defp has_hub?(hub_id) do
    case Oracle.list_hubs() do
      hubs when is_list(hubs) -> Enum.any?(hubs, &(&1.hub_id == hub_id))
      _ -> false
    end
  end

  test "exactly one oracle instance, located on the leader node", %{peer: peer} do
    start_leadership_on(node())
    start_leadership_on(peer)

    {leader, _other} = elected_leader_and_other(peer)

    assert eventually(fn -> Oracle.whereis() != :undefined end)
    assert node(Oracle.whereis()) == leader

    # The oracle is globally registered: both nodes resolve the same single pid.
    assert eventually(fn -> :erpc.call(peer, Oracle, :whereis, []) == Oracle.whereis() end)
  end

  test "oracle fails over with leadership and rebuilds its directory", %{peer: peer} do
    start_leadership_on(node())
    start_leadership_on(peer)

    {leader, other} = elected_leader_and_other(peer)
    assert eventually(fn -> Oracle.whereis() != :undefined end)

    # Announce from the surviving (future-leader) node so its manager re-announces.
    :erpc.call(other, Oracle.Manager, :announce, [:durable_hub, %{}])
    assert eventually(fn -> has_hub?(:durable_hub) end)

    # The leader steps down; the oracle must move to `other` and rebuild.
    stop_leadership_on(leader)

    assert eventually(fn ->
             pid = Oracle.whereis()
             pid != :undefined and node(pid) == other
           end)

    assert eventually(fn -> has_hub?(:durable_hub) end)
  end

  test "coordinate/2 de-duplicates the same key across nodes", %{peer: peer} do
    start_leadership_on(node())
    start_leadership_on(peer)
    elected_leader_and_other(peer)
    assert eventually(fn -> Oracle.whereis() != :undefined end)

    parent = self()
    work = {:erlang, :send, [parent, :coordinated]}

    r1 = Oracle.coordinate(:dedup_key, work)
    r2 = :erpc.call(peer, Oracle, :coordinate, [:dedup_key, work])

    assert {:ok, _} = r1
    assert {:already_done, _} = r2

    # The work executed exactly once across the cluster.
    assert_receive :coordinated, 2_000
    refute_receive :coordinated, 500
  end
end
