defmodule Test.ProcessHubReconcileMultiNodeTest do
  @moduledoc """
  The cases the orphan reconcile exists for, driven across two real nodes:

    * whole-cluster restart — every declared child returns, exactly once;
    * rejoin into a live cluster — a returning node starts nothing;
    * a stop during a node's absence — the child stays stopped on its return;
    * a child bound on two nodes — the ring owner's instance is kept.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.DeclaredChildren
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Recovery
  alias ProcessHub.Strategy.Synchronization.PubSub
  alias ProcessHub.Utility.Bag
  alias Test.Helper.Bootstrap
  alias Test.Helper.Common
  alias Test.Helper.SetupHelper
  alias Test.Helper.TestNode

  @moduletag :multinode

  # Rounds are triggered explicitly once the cluster has formed, so the grace
  # window is set beyond any test's lifetime. That also removes the timing race
  # these tests would otherwise depend on: "did the join broadcast beat the timer".
  @sync_interval_ms 300
  @no_timer_grace_ms 600_000

  defp reconcile_now(hub_id, node), do: send({hub_id, node}, :reconcile_round)

  setup_all do
    [{peer_name, peer_pid}] = TestNode.start_nodes(1, prefix: "reconcile_mn")
    :erlang.unlink(peer_pid)

    on_exit(fn ->
      if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
    end)

    {:ok, %{peer: peer_name}}
  end

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "ph_rec_mn_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, %{tmp_dir: tmp_dir}}
  end

  defp cspec(id), do: %{id: id, start: {Test.Helper.TestServer, :start_link, [%{name: id}]}}

  # Each node needs its own DETS file; peers share this machine's filesystem.
  defp hub_conf(hub_id, tmp_dir, node_name, hooks \\ %{}) do
    %ProcessHub{
      hub_id: hub_id,
      registry_backend: {:durable_ets, path: Path.join(tmp_dir, "#{node_name}.dets")},
      auto_recovery: [reconcile_grace_ms: @no_timer_grace_ms, reconcile_interval_ms: 1_000],
      synchronization_strategy: %PubSub{sync_interval: @sync_interval_ms},
      hubs_discover_interval: 300,
      cluster_event_debounce: 0,
      hooks: hooks
    }
  end

  # Only `test/helper`, `test/fixture` and `test/support` are on the peers' code
  # path, so every remote call goes through a helper module, never this one.
  defp start_hub(node, conf) when node === node(),
    do: Bootstrap.start_hub_on_node(conf, conf.hooks)

  defp start_hub(node, conf),
    do: :erpc.call(node, Bootstrap, :start_hub_on_node, [conf, conf.hooks])

  defp stop_hub(node, hub_id) when node === node(), do: ProcessHub.Initializer.stop(hub_id)
  defp stop_hub(node, hub_id), do: :erpc.call(node, ProcessHub.Initializer, :stop, [hub_id])

  defp await_normal(node, hub_id) when node === node(),
    do: Recovery.await_normal(hub_id, 20_000)

  defp await_normal(node, hub_id),
    do: :erpc.call(node, Recovery, :await_normal, [hub_id, 20_000], 25_000)

  defp dump(node, hub_id) when node === node(), do: ProcessRegistry.dump(hub_id)
  defp dump(node, hub_id), do: :erpc.call(node, ProcessRegistry, :dump, [hub_id])

  defp local_ids(node, hub_id) when node === node(),
    do: ProcessRegistry.process_list(hub_id, :local) |> Keyword.keys() |> Enum.sort()

  defp local_ids(node, hub_id) do
    :erpc.call(node, ProcessRegistry, :process_list, [hub_id, :local])
    |> Keyword.keys()
    |> Enum.sort()
  end

  defp start_cluster!(hub_id, tmp_dir, peer, hooks \\ %{}) do
    nodes = [node(), peer]

    Enum.each(nodes, fn n -> start_hub(n, hub_conf(hub_id, tmp_dir, n, hooks)) end)

    on_exit(fn -> Enum.each(nodes, fn n -> stop_hub(n, hub_id) end) end)

    settle(nodes, hub_id)
    nodes
  end

  # Runs each node's first round, but only once every node can see the whole
  # cluster and the declared-list versions have converged — a node holding a
  # stale list would reconcile against stops it has not heard of yet. This is
  # the wait the production reconcile grace provides.
  defp settle(nodes, hub_id) do
    Enum.each(nodes, fn n ->
      assert Common.eventually(fn -> member_count(n, hub_id) == 2 end, 15_000),
             "#{inspect(n)} did not see the full cluster"
    end)

    assert Common.eventually(
             fn ->
               nodes |> Enum.map(&declared_version(&1, hub_id)) |> Enum.uniq() |> length() == 1
             end,
             15_000
           ),
           "declared-list versions did not converge"

    Enum.each(nodes, &reconcile_now(hub_id, &1))
    Enum.each(nodes, fn n -> assert await_normal(n, hub_id) == :ok end)
  end

  defp declared_version(node, hub_id) when node === node(),
    do: DeclaredChildren.declared_children(hub_id).version

  defp declared_version(node, hub_id),
    do: :erpc.call(node, DeclaredChildren, :declared_children, [hub_id]).version

  defp member_count(node, hub_id) when node === node(),
    do: length(ProcessHub.nodes(hub_id, [:include_local]))

  defp member_count(node, hub_id),
    do: length(:erpc.call(node, ProcessHub, :nodes, [hub_id, [:include_local]]))

  defp started_ids(hub_id, ids) do
    Common.eventually(fn ->
      dump = ProcessRegistry.dump(hub_id)
      Enum.all?(ids, &Map.has_key?(dump, &1))
    end)

    ProcessRegistry.dump(hub_id) |> Map.keys() |> Enum.sort()
  end

  test "a whole-cluster restart restores every child exactly once",
       %{peer: peer, tmp_dir: tmp_dir} do
    hub_id = SetupHelper.unique_id(:reconcile_restart)
    nodes = start_cluster!(hub_id, tmp_dir, peer)

    ids = [:wc_a, :wc_b, :wc_c, :wc_d]

    assert %ProcessHub.StartResult{status: :ok} =
             ProcessHub.start_children(hub_id, Enum.map(ids, &cspec/1),
               awaitable: true,
               durable: true
             )
             |> ProcessHub.await()

    assert started_ids(hub_id, ids) == ids

    # Both nodes hold durable rows; bring the whole cluster down.
    before_placement = Map.new(nodes, fn n -> {n, local_ids(n, hub_id)} end)
    assert before_placement |> Map.values() |> List.flatten() |> Enum.sort() == ids

    Enum.each(nodes, fn n -> stop_hub(n, hub_id) end)

    # ...and back up with nothing running.
    Enum.each(nodes, fn n -> start_hub(n, hub_conf(hub_id, tmp_dir, n)) end)
    settle(nodes, hub_id)

    assert Common.eventually(fn -> map_size(dump(node(), hub_id)) == length(ids) end, 20_000),
           "children not restored: #{inspect(Map.keys(dump(node(), hub_id)))}"

    # Exactly once: every child on exactly one node, no id on both.
    after_placement = Map.new(nodes, fn n -> {n, local_ids(n, hub_id)} end)
    all = after_placement |> Map.values() |> List.flatten()

    assert Enum.sort(all) == ids
    assert Enum.uniq(all) == all, "a child was started on more than one node"
  end

  test "a node rejoining a live cluster starts nothing", %{peer: peer, tmp_dir: tmp_dir} do
    hub_id = SetupHelper.unique_id(:reconcile_rejoin)
    start_cluster!(hub_id, tmp_dir, peer)

    ids = [:rj_a, :rj_b, :rj_c, :rj_d]

    assert %ProcessHub.StartResult{status: :ok} =
             ProcessHub.start_children(hub_id, Enum.map(ids, &cspec/1),
               awaitable: true,
               durable: true
             )
             |> ProcessHub.await()

    assert started_ids(hub_id, ids) == ids

    # The peer goes away; the survivor migrates its children onto itself.
    stop_hub(peer, hub_id)

    assert Common.eventually(fn -> local_ids(node(), hub_id) == ids end, 20_000),
           "survivor did not adopt every child: #{inspect(local_ids(node(), hub_id))}"

    # The peer returns holding its old rows on disk.
    start_hub(peer, hub_conf(hub_id, tmp_dir, peer))
    settle([node(), peer], hub_id)

    # Its first round observed the children running on the survivor, so it
    # started none of them and no child is double-bound.
    all = local_ids(node(), hub_id) ++ local_ids(peer, hub_id)
    assert Enum.sort(Enum.uniq(all)) == ids
    assert Enum.uniq(all) == all, "a child ended up bound on both nodes"
  end

  test "a stop during a node's absence is honoured on its return",
       %{peer: peer, tmp_dir: tmp_dir} do
    hub_id = SetupHelper.unique_id(:reconcile_stop)
    start_cluster!(hub_id, tmp_dir, peer)

    ids = [:sd_a, :sd_b, :sd_c, :sd_d]

    assert %ProcessHub.StartResult{status: :ok} =
             ProcessHub.start_children(hub_id, Enum.map(ids, &cspec/1),
               awaitable: true,
               durable: true
             )
             |> ProcessHub.await()

    assert started_ids(hub_id, ids) == ids

    stop_hub(peer, hub_id)
    assert Common.eventually(fn -> local_ids(node(), hub_id) == ids end, 20_000)

    # Stopped while the peer is away — the peer's disk still says :running.
    assert %ProcessHub.StopResult{status: :ok} =
             ProcessHub.stop_children(hub_id, [:sd_b], awaitable: true) |> ProcessHub.await()

    assert ProcessHub.get_pid(hub_id, :sd_b) == nil

    start_hub(peer, hub_conf(hub_id, tmp_dir, peer))
    settle([node(), peer], hub_id)

    # The peer adopts the newer declared list rather than resurrecting the
    # child: list absence is the stop record, and no row remains either.
    declared = :erpc.call(peer, DeclaredChildren, :declared_children, [hub_id])
    refute :sd_b in Enum.map(declared.children, & &1.id)
    assert ProcessRegistry.lookup(hub_id, :sd_b, include_empty: true) == nil

    refute :sd_b in (local_ids(node(), hub_id) ++ local_ids(peer, hub_id))
    assert ProcessHub.get_pid(hub_id, :sd_b) == nil
  end

  test "a child bound on two nodes is reduced to the ring owner's instance",
       %{peer: peer, tmp_dir: tmp_dir} do
    hub_id = SetupHelper.unique_id(:reconcile_dup)
    parent = self()

    hooks = %{Hook.reconcile_duplicate() => [Bag.recv_hook(Hook.reconcile_duplicate(), parent)]}

    start_cluster!(hub_id, tmp_dir, peer, hooks)

    assert %ProcessHub.StartResult{status: :ok} =
             ProcessHub.start_children(hub_id, [cspec(:dup_a)], awaitable: true)
             |> ProcessHub.await()

    assert started_ids(hub_id, [:dup_a]) == [:dup_a]

    [{owner, _pid}] = ProcessRegistry.lookup(hub_id, :dup_a) |> elem(1)
    intruder = Enum.find([node(), peer], &(&1 !== owner))

    # Force the second binding: start the child under the intruder's supervisor
    # and register it there, which is what a ring change between two concurrent
    # submissions would produce.
    :ok = Common.bind_child_locally(intruder, hub_id, cspec(:dup_a))

    assert Common.eventually(
             fn ->
               ProcessRegistry.lookup(hub_id, :dup_a) |> elem(1) |> length() == 2
             end,
             15_000
           ),
           "the second binding never propagated"

    Enum.each([node(), peer], &reconcile_now(hub_id, &1))

    dup_hook = Hook.reconcile_duplicate()

    assert_receive {^dup_hook,
                    %{
                      hub_id: ^hub_id,
                      child_id: :dup_a,
                      instance_count: 2,
                      kept_node: ^owner,
                      stopped_nodes: [^intruder]
                    }},
                   20_000

    assert Common.eventually(
             fn ->
               ProcessRegistry.lookup(hub_id, :dup_a) |> elem(1) |> Keyword.keys() == [owner]
             end,
             15_000
           )

    assert local_ids(intruder, hub_id) == []
  end
end
