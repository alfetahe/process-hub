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

  #  @tag hub_id: :divergence_test
  # @tag partition_strategy: :div
  # @tag listed_hooks: [
  #        {Hook.post_cluster_join(), :local},
  #        {Hook.post_cluster_leave(), :local},
  #        {Hook.post_nodes_redistribution(), :local}
  #      ]
  # test "partition divergence test", %{hub_id: hub_id, listed_hooks: lh} = context do
  #   :net_kernel.monitor_nodes(true)

  #   peer_to_start = 6

  #   new_peers =
  #     TestNode.start_nodes(
  #       peer_to_start,
  #       prefix: :divergence_test
  #     )

  #   peer_names = for {peer, _pid} <- new_peers, do: peer

  #   Bootstrap.gen_hub(context)
  #   |> Bootstrap.start_hubs(peer_names, lh, new_nodes: true)

  #   assert ProcessHub.is_partitioned?(hub_id) === false

  #   Enum.reduce(1..peer_to_start, new_peers, fn _x, acc ->
  #     removed_peers = Common.stop_peers(acc, 1)
  #     remaining = Enum.filter(acc, fn node -> !Enum.member?(removed_peers, node) end)
  #     Bag.await_cluster_leave(1, scope: :local)
  #     remaining
  #   end)

  #   assert ProcessHub.is_partitioned?(hub_id) === false

  #   :net_kernel.monitor_nodes(false)
  # end

  # @tag hub_id: :dynamic_quroum_test
  # @tag partition_strategy: :dynamic
  # @tag quorum_size: 80
  # # 1 hour
  # @tag quorum_threshold_time: 3600
  # @tag listed_hooks: [
  #        {Hook.post_cluster_join(), :global},
  #        {Hook.post_cluster_leave(), :global},
  #        {Hook.post_nodes_redistribution(), :local}
  #      ]
  # test "dynamic quorum with min of 70% of cluster",
  #      %{hub_id: hub_id, listed_hooks: lh} = context do
  #   :net_kernel.monitor_nodes(true)

  #   assert ProcessHub.is_partitioned?(hub_id) === false

  #   # If @nr_of_peers = 5
  #   peer_to_start = @nr_of_peers - 1

  #   new_peers = TestNode.start_nodes(peer_to_start, prefix: :dynamic_quorum_test)
  #   peer_names = for {peer, _pid} <- new_peers, do: peer

  #   # Start hubs on new peers - Bootstrap.start_hubs already handles await_cluster_join
  #   Bootstrap.gen_hub(context) |> Bootstrap.start_hubs(peer_names, lh, new_nodes: true)

  #   assert ProcessHub.is_partitioned?(hub_id) === false

  #   # Track current cluster size as nodes leave
  #   # Cluster = @nr_of_peers + 1 (initial) + length(peer_names) (new peers)
  #   current_cluster_size = @nr_of_peers + 1 + length(peer_names)

  #   removed_peers = Common.stop_peers(new_peers, 1)
  #   new_peers = Enum.filter(new_peers, fn node -> !Enum.member?(removed_peers, node) end)
  #   Bag.await_cluster_leave(1, scope: :global, cluster_size: current_cluster_size)
  #   current_cluster_size = current_cluster_size - 1

  #   # At this point we still have 90% of cluster left.
  #   assert ProcessHub.is_partitioned?(hub_id) === false

  #   removed_peers = Common.stop_peers(new_peers, 1)
  #   new_peers = Enum.filter(new_peers, fn node -> !Enum.member?(removed_peers, node) end)
  #   Bag.await_cluster_leave(1, scope: :global, cluster_size: current_cluster_size)
  #   current_cluster_size = current_cluster_size - 1

  #   # At this point we still have 80% of cluster left.
  #   assert ProcessHub.is_partitioned?(hub_id) === false

  #   removed_peers = Common.stop_peers(new_peers, 1)
  #   _new_peers = Enum.filter(new_peers, fn node -> !Enum.member?(removed_peers, node) end)
  #   Bag.await_cluster_leave(1, scope: :global, cluster_size: current_cluster_size)

  #   # At this point we have 70% of cluster left.
  #   assert ProcessHub.is_partitioned?(hub_id) === true

  #   :net_kernel.monitor_nodes(false)
  # end

  # @tag hub_id: :majority_quorum_test
  # @tag partition_strategy: :majority
  # @tag initial_cluster_size: 1
  # @tag track_max_size: true
  # @tag listed_hooks: [
  #        {Hook.post_cluster_join(), :global},
  #        {Hook.post_cluster_leave(), :local},
  #        {Hook.post_nodes_redistribution(), :local}
  #      ]
  # test "majority quorum with adaptive cluster sizing",
  #      %{hub_id: hub_id, listed_hooks: lh} = context do
  #   :net_kernel.monitor_nodes(true)

  #   assert ProcessHub.is_partitioned?(hub_id) === false

  #   # Start 4 additional nodes, growing cluster to 10 nodes
  #   # max_seen should become 10, quorum required = 6 (div(10, 2) + 1)
  #   peers_to_start = 4
  #   new_peers = TestNode.start_nodes(peers_to_start, prefix: :majority_quorum_test_batch)
  #   peer_names = for {peer, _pid} <- new_peers, do: peer

  #   Bootstrap.gen_hub(context) |> Bootstrap.start_hubs(peer_names, lh, new_nodes: true)
  #   Bag.receive_multiple(peers_to_start, Hook.post_nodes_redistribution())

  #   # With 10 nodes, quorum = 6, we have quorum
  #   assert ProcessHub.is_partitioned?(hub_id) === false

  #   # Remove 1 node → 9 nodes remaining
  #   # max_seen still 10, quorum still 6, we have 9 >= 6
  #   removed_peers = Common.stop_peers(new_peers, 1)

  #   remaining_new_peers =
  #     Enum.filter(new_peers, fn node -> !Enum.member?(removed_peers, node) end)

  #   Bag.receive_multiple(1, Hook.post_nodes_redistribution())

  #   assert ProcessHub.is_partitioned?(hub_id) === false

  #   # Remove 2 more nodes → 7 nodes remaining
  #   # max_seen still 10, quorum still 6, we have 7 >= 6
  #   removed_peers = Common.stop_peers(remaining_new_peers, 2)

  #   remaining_new_peers =
  #     Enum.filter(remaining_new_peers, fn node -> !Enum.member?(removed_peers, node) end)

  #   Bag.receive_multiple(2, Hook.post_nodes_redistribution())

  #   assert ProcessHub.is_partitioned?(hub_id) === false

  #   # Remove 1 more node → 6 nodes remaining (exactly at quorum)
  #   # max_seen still 10, quorum still 6, we have 6 >= 6
  #   removed_peers = Common.stop_peers(remaining_new_peers, 1)

  #   _remaining_new_peers =
  #     Enum.filter(remaining_new_peers, fn node -> !Enum.member?(removed_peers, node) end)

  #   Bag.receive_multiple(1, Hook.post_nodes_redistribution())

  #   assert ProcessHub.is_partitioned?(hub_id) === false

  #   # All new peers have been stopped, cluster back to original 6 nodes
  #   # But max_seen is still 10, so quorum is still 6
  #   # With 6 nodes we're exactly at quorum

  #   # Now test that strategy remembers max_seen across all nodes
  #   # The fact that we still have quorum proves max_seen = 10 is tracked

  #   :net_kernel.monitor_nodes(false)
  # end
end
