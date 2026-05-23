defmodule Test.ProcessHubNodePurgeTest do
  @moduledoc """
  Increment 1 — delete-only dead-node registry purge primitives.
  """
  use ExUnit.Case

  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.ProcessRegistry

  @hub_id :node_purge_test

  setup %{} do
    Test.Helper.SetupHelper.setup_base(%{}, @hub_id)
  end

  defp spec(id), do: %{id: id, start: {Agent, :start_link, [fn -> :ok end]}}

  test "purge_node removes the node's pids and keeps other locations", %{hub_id: hub_id} do
    fake = :"fake1@127.0.0.1"

    ProcessRegistry.bulk_insert(hub_id, %{
      "multi" => {spec("multi"), [{node(), self()}, {fake, self()}], %{}}
    })

    assert Cluster.purge_node(hub_id, fake) == ["multi"]

    {_spec, nodes} = ProcessRegistry.lookup(hub_id, "multi")
    assert Keyword.keys(nodes) == [node()]
  end

  test "purge_node deletes entries left with no remaining locations", %{hub_id: hub_id} do
    fake = :"fake2@127.0.0.1"

    ProcessRegistry.bulk_insert(hub_id, %{
      "only_fake" => {spec("only_fake"), [{fake, self()}], %{}}
    })

    assert Cluster.purge_node(hub_id, fake) == ["only_fake"]

    assert ProcessRegistry.lookup(hub_id, "only_fake") == nil
    refute ProcessRegistry.entry_exists?(hub_id, "only_fake")
  end

  test "purge_node returns [] when the node is not referenced", %{hub_id: hub_id} do
    ProcessRegistry.bulk_insert(hub_id, %{
      "local_only" => {spec("local_only"), [{node(), self()}], %{}}
    })

    assert Cluster.purge_node(hub_id, :"ghost@127.0.0.1") == []

    {_spec, [{n, _pid}]} = ProcessRegistry.lookup(hub_id, "local_only")
    assert n == node()
  end

  test "purge_dead_nodes purges nodes not in the cluster and keeps live ones", %{hub_id: hub_id} do
    dead1 = :"dead1@127.0.0.1"
    dead2 = :"dead2@127.0.0.1"

    ProcessRegistry.bulk_insert(hub_id, %{
      "c1" => {spec("c1"), [{node(), self()}, {dead1, self()}], %{}},
      "c2" => {spec("c2"), [{dead2, self()}], %{}}
    })

    dead = Cluster.purge_dead_nodes(hub_id)
    assert Enum.sort(dead) == Enum.sort([dead1, dead2])

    # c1 keeps the live local node.
    {_spec, n1} = ProcessRegistry.lookup(hub_id, "c1")
    assert Keyword.keys(n1) == [node()]

    # c2 had only a dead node, so it is removed entirely.
    assert ProcessRegistry.lookup(hub_id, "c2") == nil
  end

  test "purge_node then purge_dead_nodes leaves a fully-scrubbed registry", %{hub_id: hub_id} do
    dead = :"dead3@127.0.0.1"

    ProcessRegistry.bulk_insert(hub_id, %{
      "d" => {spec("d"), [{node(), self()}, {dead, self()}], %{}}
    })

    assert Cluster.purge_node(hub_id, dead) == ["d"]
    # The dead node was already scrubbed, so nothing left to purge.
    assert Cluster.purge_dead_nodes(hub_id) == []
  end
end
