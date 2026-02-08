defmodule Test.TempTest do
  alias Test.Helper.TestNode
  alias Test.Helper.Common
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Constant.Hook
  alias Test.Helper.Bootstrap

  use ExUnit.Case, async: false

  # Total nr of nodes to start (without the main node)
  @nr_of_peers 5


  setup_all context do
    context = Map.put(context, :validate_metadata, false)

    Map.merge(Bootstrap.init_nodes(@nr_of_peers), context)
  end

  setup context do
    Bootstrap.bootstrap(context)
  end

  @tag hub_id: :static_quroum_test
  @tag partition_strategy: :static
  @tag quorum_size: @nr_of_peers + 2
  @tag quorum_startup_confirm: true
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :global},
         {Hook.post_cluster_leave(), :local},
         {Hook.post_nodes_redistribution(), :local}
       ]
  test "static quorum with min of #{@nr_of_peers + 2} nodes",
       %{hub_id: hub_id, peer_nodes: peers, listed_hooks: lh} = context do
    :net_kernel.monitor_nodes(true)
    # We don't have enough nodes to form the cluster and startup_confirm is set `true`
    assert ProcessHub.is_partitioned?(hub_id) === true

    peers_to_start = @nr_of_peers - 3
    new_peers = TestNode.start_nodes(peers_to_start, prefix: :static_quorum_test_batch1)
    peer_names = for {peer, _pid} <- new_peers, do: peer

    Bootstrap.gen_hub(context)
    |> Bootstrap.start_hubs(peer_names, lh, new_nodes: true, skip_await: true)

    Bag.receive_multiple(peers_to_start, Hook.post_nodes_redistribution())

    # Flush any stale messages from the join phase.
    Bag.all_messages()

    # We have added `peers_to_start` nodes so our cluster shouldn't be partitioned anymore.
    assert ProcessHub.is_partitioned?(hub_id) === false

    removed_peers = Common.stop_peers(new_peers, 1)
    new_peers = Enum.filter(new_peers, fn node -> !Enum.member?(removed_peers, node) end)
    Bag.receive_multiple(1, Hook.post_cluster_leave())

    # We still achive quorum
    assert ProcessHub.is_partitioned?(hub_id) === false

    removed_peers = Common.stop_peers(new_peers, 1)
    _new_peers = Enum.filter(peers, fn node -> !Enum.member?(removed_peers, node) end)
    Bag.receive_multiple(1, Hook.post_cluster_leave())

    # Quorum not achieved
    assert ProcessHub.is_partitioned?(hub_id) === true

    :net_kernel.monitor_nodes(false)
  end
end
