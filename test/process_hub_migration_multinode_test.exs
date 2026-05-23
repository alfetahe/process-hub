defmodule Test.ProcessHubMigrationMultinodeTest do
  @moduledoc """
  Increment 4 — multi-node migration: two hubs clustered across two nodes, the
  migration requested from a peer node, coordinated by the leader-hosted oracle,
  with cross-node state handoff.
  """
  use ExUnit.Case, async: false

  import Test.Helper.LeadershipCluster

  alias Test.Helper.TestNode
  alias Test.Helper.Bootstrap
  alias Test.Helper.TestServer
  alias ProcessHub.Service.Leadership
  alias ProcessHub.Service.Oracle

  @hub_a :migr_mn_a
  @hub_b :migr_mn_b

  setup do
    Leadership.stop()

    [{peer, peer_pid}] = TestNode.start_nodes(1, prefix: "migr_mn")
    :erlang.unlink(peer_pid)

    on_exit(fn ->
      Leadership.stop()
      stop_hub_everywhere(@hub_a, peer)
      stop_hub_everywhere(@hub_b, peer)
      if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
    end)

    %{peer: peer}
  end

  defp stop_hub_everywhere(hub_id, peer) do
    swallow(fn -> ProcessHub.Initializer.stop(hub_id) end)
    swallow(fn -> :erpc.call(peer, ProcessHub.Initializer, :stop, [hub_id]) end)
  end

  defp swallow(fun) do
    try do
      fun.()
    catch
      _kind, _reason -> :ok
    end
  end

  # No debounce so the 200ms discovery events are not coalesced away.
  defp start_clustered_hub(hub_id, peer) do
    conf = %ProcessHub{hub_id: hub_id, hubs_discover_interval: 200, cluster_event_debounce: 0}
    :erpc.call(peer, Bootstrap, :start_hub_on_node, [conf, %{}])
    {:ok, pid} = ProcessHub.Initializer.start_link(conf)
    :erlang.unlink(pid)

    assert eventually(
             fn ->
               length(ProcessHub.nodes(hub_id, [:include_local])) == 2 and
                 length(:erpc.call(peer, ProcessHub, :nodes, [hub_id, [:include_local]])) == 2
             end,
             15_000
           )
  end

  test "migration requested from a peer moves the process with its state", %{peer: peer} do
    # Cluster the hubs first; then opt into leadership.
    start_clustered_hub(@hub_a, peer)
    start_clustered_hub(@hub_b, peer)

    start_leadership_on(node())
    start_leadership_on(peer)
    elected_leader_and_other(peer)
    assert eventually(fn -> Oracle.whereis() != :undefined end)

    spec = %{id: "mw", start: {TestServer, :start_link, [%{name: "mw"}]}}
    ProcessHub.start_child(@hub_a, spec, awaitable: true) |> ProcessHub.Future.await()

    # Wait until the registration has synced to both nodes, so whichever node
    # hosts the oracle can resolve the source process.
    assert eventually(fn ->
             ProcessHub.child_lookup(@hub_a, "mw") != nil and
               :erpc.call(peer, ProcessHub, :child_lookup, [@hub_a, "mw"]) != nil
           end)

    {_spec, [{_node, pid}]} = ProcessHub.child_lookup(@hub_a, "mw")
    GenServer.call(pid, {:set_value, :counter, 99})

    # The peer initiates; the oracle (on the leader) coordinates the migration.
    assert {:ok, _info} = :erpc.call(peer, ProcessHub, :migrate_process, [@hub_a, @hub_b, "mw"])

    assert eventually(fn -> ProcessHub.child_lookup(@hub_b, "mw") != nil end)
    assert eventually(fn -> ProcessHub.child_lookup(@hub_a, "mw") == nil end)

    {_spec, [{_node, new_pid}]} = ProcessHub.child_lookup(@hub_b, "mw")
    # Handover is delivered asynchronously, so poll for it.
    assert eventually(fn -> GenServer.call(new_pid, {:get_value, :counter}) == 99 end)
  end
end
