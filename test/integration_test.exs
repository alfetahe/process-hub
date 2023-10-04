defmodule Test.IntegrationTest do
  alias Test.Helper.TestNode
  alias ProcessHub.Utility.Bag
  alias Test.Helper.Common
  alias Test.Helper.Bootstrap
  alias ProcessHub.Constant.Hook

  use ExUnit.Case, async: false

  setup context do
    Test.Helper.Bootstrap.bootstrap(context)
  end

  @tag nodes: 3
  @tag hub_id: :pubsub_start_rem_test
  @tag sync_strategy: :pubsub
  @tag listed_hooks: [
         {Hook.cluster_join(), :local},
         {Hook.registry_pid_inserted(), :local},
         {Hook.registry_pid_removed(), :local}
       ]
  test "pubsub children starting and removing", %{hub_id: hub_id} = context do
    child_count = 100
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    # Starts children on all nodes.
    Common.sync_base_test(context, child_specs, :add)

    # Tests if all child_specs are used for starting children.
    Common.validate_registry_length(context, child_specs)

    # Tests if all child_specs are started on all nodes.
    Common.validate_started_children(context, child_specs)

    # Tests children adding and syncing.
    Common.validate_sync(context)

    # Stops children on all nodes.
    Common.sync_base_test(context, child_specs, :rem)

    # Tests children removing and syncing.
    Common.validate_sync(context)
  end

  @tag nodes: 3
  @tag hub_id: :pubsub_interval_test
  @tag sync_strategy: :pubsub
  @tag listed_hooks: [
         {Hook.cluster_join(), :local},
         {Hook.registry_pid_inserted(), :global},
         {Hook.registry_pid_removed(), :global}
       ]
  test "pubsub interval sync test", %{hub_id: hub_id} = context do
    child_count = 100
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    # Locally start children without propagating to the rest of the cluster.
    Common.periodic_sync_base(context, child_specs, :add)

    # Manually trigger the periodic sync.
    Common.trigger_periodc_sync(context, child_specs, :add)

    # Test if data is synchronized in the cluster.
    Common.validate_sync(context)

    # Locally stop children without propagating to the rest of the cluster.
    Common.periodic_sync_base(context, child_specs, :rem)

    # Manually trigger the periodic sync.
    Common.trigger_periodc_sync(context, child_specs, :rem)

    # Test if data is synchronized in the cluster.
    Common.validate_sync(context)
  end

  @tag nodes: 3
  @tag hub_id: :gossip_start_rem_test
  @tag sync_strategy: :gossip
  @tag listed_hooks: [
         {Hook.cluster_join(), :local},
         {Hook.registry_pid_inserted(), :local},
         {Hook.registry_pid_removed(), :local}
       ]
  test "gossip children starting and removing", %{hub_id: hub_id} = context do
    child_count = 100
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    # Starts children on all nodes.
    Common.sync_base_test(context, child_specs, :add, scope: :local)

    # Tests if all child_specs are used for starting children.
    Common.validate_registry_length(context, child_specs)

    # Tests if all child_specs are started on all nodes.
    Common.validate_started_children(context, child_specs)

    # Tests children adding and syncing.
    Common.validate_sync(context)

    # Stops children on all nodes.
    Common.sync_base_test(context, child_specs, :rem, scope: :local)

    # Tests children removing and syncing.
    Common.validate_sync(context)
  end

  @tag nodes: 3
  @tag hub_id: :gossip_interval_test
  @tag sync_strategy: :gossip
  @tag listed_hooks: [
         {Hook.cluster_join(), :local},
         {Hook.registry_pid_inserted(), :global},
         {Hook.registry_pid_removed(), :global}
       ]
  test "gossip interval sync test", %{hub_id: hub_id} = context do
    child_count = 100
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    # Locally start children without propagating to the rest of the cluster.
    Common.periodic_sync_base(context, child_specs, :add)

    # Manually trigger the periodic sync.
    Common.trigger_periodc_sync(context, child_specs, :add)

    # Test if data is synchronized in the cluster.
    Common.validate_sync(context)

    # Locally stop children without propagating to the rest of the cluster.
    Common.periodic_sync_base(context, child_specs, :rem)

    # Manually trigger the periodic sync.
    Common.trigger_periodc_sync(context, child_specs, :rem)

    # Test if data is synchronized in the cluster.
    Common.validate_sync(context)
  end

  @tag nodes: 3
  @tag redun_strategy: :replication
  @tag hub_id: :redunc_activ_pass_test
  @tag replication_factor: 4
  @tag listed_hooks: [
         {Hook.cluster_join(), :local},
         {Hook.registry_pid_inserted(), :global},
         {Hook.registry_pid_removed(), :global}
       ]
  test "replication factor and mode", %{hub_id: hub_id} = context do
    child_count = 100
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    # Starts children on all nodes.
    Common.sync_base_test(context, child_specs, :add)

    Bag.receive_multiple(
      context.nodes * child_count * context.replication_factor,
      {Hook.registry_pid_inserted(), Hook.registry_pid_inserted()}
    )

    # Tests if all child_specs are used for starting children.
    Common.validate_registry_length(context, child_specs)

    # Tests redundancy and check if started children's count matches replication factor.
    Common.validate_replication(context)

    # Tests redundancy mode and check if replicated children are in passive/active mode.
    Common.validate_redundancy_mode(context)
  end

  @tag nodes: 3
  @tag redun_strategy: :singularity
  @tag hub_id: :redunc_singulary_test
  @tag listed_hooks: [
         {Hook.cluster_join(), :local},
         {Hook.registry_pid_inserted(), :local}
       ]
  test "redundancy with singularity", %{hub_id: hub_id} = context do
    child_count = 100
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    # Starts children on all nodes.
    Common.sync_base_test(context, child_specs, :add)

    # Tests if all child_specs are used for starting children.
    Common.validate_registry_length(context, child_specs)

    # Tests if all child_specs are started on all nodes.
    Common.validate_started_children(context, child_specs)

    # Tests redundancy and check if started children's count matches replication factor.
    Common.validate_singularity(context)
  end

  @tag nodes: 2
  @tag hub_id: :divergence_test
  @tag partition_strategy: :div
  @tag listed_hooks: [
         {Hook.cluster_join(), :local},
         {Hook.post_nodes_redistribution(), :global}
       ]
  test "partition divergence test",
       %{hub_id: hub_id, peer_nodes: peers, nodes: nodes_count} = _context do
    Common.even_sum_sequence(2, nodes_count)
    |> Bag.receive_multiple(Hook.post_nodes_redistribution())

    :net_kernel.monitor_nodes(true)

    assert ProcessHub.is_partitioned?(hub_id) === false

    end_num = nodes_count - 1

    Enum.reduce(nodes_count..end_num, peers, fn numb, acc ->
      removed_peers = Common.stop_peers(acc, 1)
      Bag.receive_multiple(numb, Hook.post_nodes_redistribution())
      Enum.filter(acc, fn node -> !Enum.member?(removed_peers, node) end)
    end)

    assert ProcessHub.is_partitioned?(hub_id) === false

    :net_kernel.monitor_nodes(false)
  end

  @tag nodes: 5
  @tag hub_id: :static_quroum_test
  @tag partition_strategy: :static
  @tag quorum_size: 4
  @tag startup_confirm: true
  @tag listed_hooks: [
         {Hook.cluster_join(), :local},
         {Hook.cluster_leave(), :global},
         {Hook.post_nodes_redistribution(), :global}
       ]
  test "static quorum with min of 4 nodes",
       %{hub_id: hub_id, peer_nodes: peers, nodes: nodes_count, listed_hooks: lh} = context do
    Common.even_sum_sequence(2, nodes_count)
    |> Bag.receive_multiple(Hook.post_nodes_redistribution())

    :net_kernel.monitor_nodes(true)

    assert ProcessHub.is_partitioned?(hub_id) === false

    end_num = nodes_count - 1

    new_peers =
      Enum.reduce(nodes_count..end_num, peers, fn numb, acc ->
        removed_peers = Common.stop_peers(acc, 1)
        Bag.receive_multiple(numb, Hook.post_nodes_redistribution())
        Enum.filter(acc, fn node -> !Enum.member?(removed_peers, node) end)
      end)

    # At this point we still have 4 nodes left which is our quorum
    assert ProcessHub.is_partitioned?(hub_id) === false

    removed_peers = Common.stop_peers(new_peers, 1)
    _peers = Enum.filter(peers, fn node -> !Enum.member?(removed_peers, node) end)

    Bag.receive_multiple(3, Hook.post_nodes_redistribution())
    Bag.receive_multiple(end_num + nodes_count + 3, Hook.cluster_leave())

    assert ProcessHub.is_partitioned?(hub_id) === true

    # Start one additional node and check if quorum is achieved.
    [{name, _pid}] = TestNode.start_nodes(:static_quorum_extras, 1)

    Bootstrap.gen_hub(context)
    |> Bootstrap.start_hubs([name], lh, true)

    Bag.receive_multiple(6, Hook.post_nodes_redistribution())
    assert ProcessHub.is_partitioned?(hub_id) === false

    :net_kernel.monitor_nodes(false)
  end

  # 6 nodes in total including the main node.
  @tag nodes: 5
  @tag hub_id: :dynamic_quroum_test
  @tag partition_strategy: :dynamic
  @tag quorum_size: 50
  # 1 hour
  @tag quorum_threshold_time: 3600
  @tag listed_hooks: [
         {Hook.cluster_join(), :local},
         {Hook.cluster_leave(), :local},
         {Hook.post_nodes_redistribution(), :global}
       ]
  test "dynamic quorum with min of 50% of cluster",
       %{hub_id: hub_id, peer_nodes: peers, nodes: nodes_count, listed_hooks: lh} = context do
    Common.even_sum_sequence(2, nodes_count)
    |> Bag.receive_multiple(Hook.post_nodes_redistribution())

    :net_kernel.monitor_nodes(true)

    assert ProcessHub.is_partitioned?(hub_id) === false

    end_num = nodes_count - 2

    new_peers =
      Enum.reduce(nodes_count..end_num, peers, fn numb, acc ->
        removed_peers = Common.stop_peers(acc, 1)
        Bag.receive_multiple(numb, Hook.post_nodes_redistribution())
        Enum.filter(acc, fn node -> !Enum.member?(removed_peers, node) end)
      end)

    # At this point we still have 50% of cluster left.
    assert ProcessHub.is_partitioned?(hub_id) === false

    # Remove one more node and we have to be locked now. We have 2 nodes left
    # after this in the cluster (including the main node)
    _removed_peers = Common.stop_peers(new_peers, 1)
    Bag.receive_multiple(2, Hook.post_nodes_redistribution())
    Bag.receive_multiple(4, Hook.cluster_leave())

    # Less than 50% of the cluster(2 nodes) are available so we should be locked now.
    assert ProcessHub.is_partitioned?(hub_id) === true

    # Start two additional node. Then our cluster has 4 nodes in total includes
    # the local.
    [{name1, _pid1}, {name2, _pid2}] = TestNode.start_nodes(:dynamic_quorum_extras, 2)

    Bootstrap.gen_hub(context)
    |> Bootstrap.start_hubs([name1, name2], lh, true)

    Bag.receive_multiple(6, Hook.post_nodes_redistribution())

    # We now have again atleast 50% of the treshold cluster left. (4 down vs 4 up)
    assert ProcessHub.is_partitioned?(hub_id) === false

    :net_kernel.monitor_nodes(false)
  end

  @tag nodes: 3
  @tag migr_strategy: :cold
  @tag hub_id: :migration_coldswap_test
  @tag redun_strategy: :replication
  @tag replication_factor: 2
  @tag listed_hooks: [
         {Hook.cluster_join(), :local},
         {Hook.cluster_leave(), :global},
         {Hook.registry_pid_inserted(), :global},
         {Hook.child_migrated(), :global}
       ]
  test "coldswap migration with replication",
       %{hub_id: hub_id, nodes: nodes_count, replication_factor: rf, listed_hooks: lh} = context do
    child_count = 10
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    # Stop hubs on peer nodes before we start.
    Enum.each(Node.list(), fn node ->
      :erpc.call(node, ProcessHub.Initializer, :stop, [hub_id])
    end)

    # Confirm that hubs are stopped.
    Bag.receive_multiple(nodes_count, Hook.cluster_leave())

    # Starts children.
    Common.sync_base_test(context, child_specs, :add)

    # Add custom data to children.
    Enum.each(child_specs, fn child_spec ->
      {_child_spec, [{_, pid}]} = ProcessHub.child_lookup(hub_id, child_spec.id)
      Process.send(pid, {:set_value, :handoff_data, child_spec.id}, [])
    end)

    # Restart hubs on peer nodes and confirm they are up and running.
    Bootstrap.gen_hub(context)
    |> Bootstrap.start_hubs(Node.list(), lh, true)

    ring = ProcessHub.Service.Ring.get_ring(hub_id)
    local_node = node()

    # Get all children that have been migrated. Meaning the old ones are killed
    # and spawned on other nodes. We can check all that no longer live on the main
    # node.
    migrated_children =
      Enum.map(child_specs, fn child_spec ->
        {child_spec.id, ProcessHub.Service.Ring.key_to_nodes(ring, child_spec.id, rf)}
      end)
      |> Enum.filter(fn {_, nodes} ->
        !Enum.member?(nodes, local_node)
      end)

    # Confirm that all migrated children have been updated.
    Bag.receive_multiple(
      length(migrated_children),
      Hook.registry_pid_inserted(),
      error_msg: "Child added timeout"
    )

    Bag.receive_multiple(
      length(migrated_children) * rf,
      Hook.registry_pid_inserted(),
      error_msg: "Child added timeout"
    )
  end

  @tag nodes: 3
  @tag migr_strategy: :hot
  @tag hub_id: :migration_hotswap_test
  @tag migr_handover: true
  @tag migr_retention: 1000
  @tag listed_hooks: [
         {Hook.cluster_join(), :local},
         {Hook.cluster_leave(), :global},
         {Hook.registry_pid_inserted(), :local},
         {Hook.registry_pid_removed(), :local},
         {Hook.post_nodes_redistribution(), :local}
       ]
  test "hotswap migration with handoff",
       %{hub_id: hub_id, nodes: nodes_count, listed_hooks: lh} = context do
    child_count = 10
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    # Stop hubs on peer nodes before we start.
    Enum.each(Node.list(), fn node ->
      :erpc.call(node, ProcessHub.Initializer, :stop, [hub_id])
    end)

    # Confirm that hubs are stopped.
    Bag.receive_multiple(nodes_count, Hook.cluster_leave(), error_msg: "Cluster leave timeout")

    # Starts children.
    Common.sync_base_test(context, child_specs, :add)

    # Add custom data to children.
    Enum.each(child_specs, fn child_spec ->
      {_child_spec, [{_, pid}]} = ProcessHub.child_lookup(hub_id, child_spec.id)
      Process.send(pid, {:set_value, :handoff_data, child_spec.id}, [])
    end)

    # Restart hubs on peer nodes and confirm they are up and running.
    Bootstrap.gen_hub(context)
    |> Bootstrap.start_hubs(Node.list(), lh, true)

    Bag.receive_multiple(nodes_count, Hook.post_nodes_redistribution(),
      error_msg: "Post redistribution timeout"
    )

    ring = ProcessHub.Service.Ring.get_ring(hub_id)
    local_node = node()

    # Get all children that have been migrated.
    migrated_children =
      Enum.map(child_specs, fn child_spec ->
        {child_spec.id, ProcessHub.Service.Ring.key_to_nodes(ring, child_spec.id, 1)}
      end)
      |> Enum.filter(fn {_, nodes} ->
        !Enum.member?(nodes, local_node)
      end)

    mcl = length(migrated_children)

    # Confirm that all migrated children have been updated.
    Bag.receive_multiple(mcl, Hook.registry_pid_removed())

    # Validate the data.
    Enum.each(migrated_children, fn {child_id, _nodes} ->
      pid =
        ProcessHub.child_lookup(hub_id, child_id)
        |> elem(1)
        |> Enum.at(0)
        |> elem(1)

      handover_data = GenServer.call(pid, {:get_value, :handoff_data})

      assert handover_data === child_id, "Data mismatch for child #{child_id}"
    end)
  end
end
