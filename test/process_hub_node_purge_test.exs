defmodule Test.ProcessHubNodePurgeTest do
  @moduledoc """
  Dead-node registry purge primitives. Purging withdraws a node's observations; a
  child left with no observation keeps its row and becomes an orphan-reconcile
  candidate rather than being erased.
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

  test "purge_node unbinds entries left with no remaining locations but keeps the row",
       %{hub_id: hub_id} do
    fake = :"fake2@127.0.0.1"

    ProcessRegistry.bulk_insert(hub_id, %{
      "only_fake" => {spec("only_fake"), [{fake, self()}], %{}}
    })

    assert Cluster.purge_node(hub_id, fake) == ["only_fake"]

    # Unbound, so invisible to placement lookups...
    assert ProcessRegistry.lookup(hub_id, "only_fake") == nil
    # ...but still registered, so the reconcile can restore it.
    assert ProcessRegistry.entry_exists?(hub_id, "only_fake")

    assert {_spec, [], _meta} =
             ProcessRegistry.lookup(hub_id, "only_fake",
               with_metadata: true,
               include_empty: true
             )
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

    # c2 had only a dead node, so it is left unbound.
    assert ProcessRegistry.lookup(hub_id, "c2") == nil
    assert ProcessRegistry.entry_exists?(hub_id, "c2")
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

  describe "handle_boot_announcement/3 (fast-restart reaping)" do
    # Reproduces the fast-restart gap: a peer that returns within :net_ticktime
    # fires no :nodedown, so the cluster keeps its now-dead bindings until it
    # announces a new boot token. Backend-independent — verified on `:ets`.
    test "a changed boot token reaps the returning node's dead bindings", %{hub_id: hub_id, hub: hub} do
      peer = :"peer_a@127.0.0.1"
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, _, _, _}

      ProcessRegistry.bulk_insert(hub_id, %{"child_x" => {spec("child_x"), [{peer, dead}], %{}}})

      Cluster.handle_boot_announcement(hub, peer, 1)

      assert ProcessRegistry.lookup(hub_id, "child_x") == nil
    end

    test "a repeated token is a no-op (flap keeps live bindings)", %{hub_id: hub_id, hub: hub} do
      peer = :"peer_b@127.0.0.1"
      ProcessRegistry.bulk_insert(hub_id, %{"child_y" => {spec("child_y"), [{peer, self()}], %{}}})

      Cluster.handle_boot_announcement(hub, peer, 7)
      ProcessRegistry.bulk_insert(hub_id, %{"child_y" => {spec("child_y"), [{peer, self()}], %{}}})
      Cluster.handle_boot_announcement(hub, peer, 7)

      assert {_spec, [{^peer, _pid}]} = ProcessRegistry.lookup(hub_id, "child_y")
    end
  end
end
