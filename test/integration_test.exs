defmodule Test.IntegrationTest do
  alias Test.Helper.TestNode
  alias ProcessHub.Utility.Bag
  alias Test.Helper.Common
  alias Test.Helper.Bootstrap
  alias ProcessHub.Constant.Hook

  use ExUnit.Case, async: false

  # Total nr of nodes to start (without the main node)
  @nr_of_peers 5

  setup_all context do
    Map.merge(Test.Helper.Bootstrap.init_nodes(@nr_of_peers), context)
  end

  setup context do
    Test.Helper.Bootstrap.bootstrap(context)
  end

  @tag hub_id: :guided_pubsub_add_rem_test
  @tag sync_strategy: :pubsub
  @tag dist_strategy: :guided
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :local},
         {Hook.registry_pid_inserted(), :global},
         {Hook.registry_pid_removed(), :global}
       ]
  test "guided pubsub children starting and removing", %{hub_id: hub_id} = context do
    child_count = 1000
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    assert ProcessHub.start_children(hub_id, child_specs) === {:error, :missing_child_mapping},
           "Children should not be started without mapping"

    assert ProcessHub.start_children(hub_id, child_specs, child_mapping: %{invalid: :invalid}) ===
             {:error, :child_mapping_mismatch},
           "Children should not be started with mismatched mapping"

    assert ProcessHub.start_children(hub_id, child_specs, child_mapping: [invalid: :invalid]) ===
             {:error, :invalid_child_mapping},
           "Children should not be started with invalid mapping"

    hub_nodes = ProcessHub.Service.Cluster.nodes(hub_id, [:include_local])

    child_mappings =
      Enum.map(child_specs, fn child_spec ->
        {child_spec.id, [Enum.random(hub_nodes)]}
      end)
      |> Map.new()

    Common.sync_base_test(context, child_specs, :add,
      scope: :global,
      start_opts: [child_mapping: child_mappings]
    )

    registry_data = ProcessHub.process_registry(hub_id)

    assert length(Map.keys(registry_data)) === length(Map.keys(child_mappings))

    assert Enum.all?(registry_data, fn {key, {_, nodes}} ->
             Enum.map(nodes, &elem(&1, 0)) === child_mappings[key]
           end)

    Common.sync_base_test(context, child_specs, :rem, scope: :global)

    assert ProcessHub.process_registry(hub_id) === %{}
  end

  @tag hub_id: :pubsub_start_rem_test
  @tag sync_strategy: :pubsub
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :local},
         {Hook.registry_pid_inserted(), :global},
         {Hook.registry_pid_removed(), :global}
       ]
  test "pubsub children starting and removing", %{hub_id: hub_id} = context do
    child_count = 1000
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    # Starts children on all nodes.
    Common.sync_base_test(context, child_specs, :add, scope: :global)

    # Tests if all child_specs are used for starting children.
    Common.validate_registry_length(context, child_specs)

    # Tests if all child_specs are started on all nodes.
    Common.validate_started_children(context, child_specs)

    # Tests children adding and syncing.
    Common.validate_sync(context)

    # Stops children on all nodes.
    Common.sync_base_test(context, child_specs, :rem, scope: :global)

    # Tests children removing and syncing.
    Common.validate_sync(context)
  end

  @tag hub_id: :pubsub_interval_test
  @tag sync_strategy: :pubsub
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :local},
         {Hook.registry_pid_inserted(), :global},
         {Hook.registry_pid_removed(), :global}
       ]
  test "pubsub interval sync test", %{hub_id: hub_id} = context do
    child_count = 1000
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

  @tag hub_id: :gossip_start_rem_test
  @tag sync_strategy: :gossip
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :local},
         {Hook.registry_pid_inserted(), :global},
         {Hook.registry_pid_removed(), :global}
       ]
  test "gossip children starting and removing", %{hub_id: hub_id} = context do
    child_count = 1000
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    # Starts children on all nodes.
    Common.sync_base_test(context, child_specs, :add, scope: :global)

    # Tests if all child_specs are used for starting children.
    Common.validate_registry_length(context, child_specs)

    # Tests if all child_specs are started on all nodes.
    Common.validate_started_children(context, child_specs)

    # Tests children adding and syncing.
    Common.validate_sync(context)

    # Stops children on all nodes.
    Common.sync_base_test(context, child_specs, :rem, scope: :global)

    # Tests children removing and syncing.
    Common.validate_sync(context)
  end

  @tag hub_id: :gossip_interval_test
  @tag sync_strategy: :gossip
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :local},
         {Hook.registry_pid_inserted(), :global},
         {Hook.registry_pid_removed(), :global}
       ]
  test "gossip interval sync test", %{hub_id: hub_id} = context do
    child_count = 1000
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

  @tag redun_strategy: :replication
  @tag hub_id: :redunc_activ_pass_test
  @tag replication_model: :active_passive
  @tag replication_factor: 4
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :local},
         {Hook.registry_pid_inserted(), :global},
         {Hook.registry_pid_removed(), :global}
       ]
  test "replication factor and mode", %{hub_id: hub_id, replication_factor: rf} = context do
    child_count = 1000
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    # Starts children on all nodes.
    Common.sync_base_test(context, child_specs, :add, scope: :global, replication_factor: rf)

    # Tests if all child_specs are used for starting children.
    Common.validate_registry_length(context, child_specs)

    # Tests redundancy and check if started children's count matches replication factor.
    Common.validate_replication(context)

    # Tests redundancy mode and check if replicated children are in passive/active mode.
    Common.validate_redundancy_mode(context)
  end

  @tag redun_strategy: :replication
  @tag hub_id: :redunc_activ_activ_test
  @tag replication_factor: :cluster_size
  @tag replication_model: :active_active
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :local},
         {Hook.registry_pid_inserted(), :global},
         {Hook.registry_pid_removed(), :global}
       ]
  test "replication cluster size with mode active active",
       %{hub_id: hub_id, hub: hub} = context do
    child_count = 1000
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))
    repl_fact = ProcessHub.Strategy.Redundancy.Base.replication_factor(hub.redundancy_strategy)

    # Starts children on all nodes.
    Common.sync_base_test(context, child_specs, :add,
      scope: :global,
      replication_factor: repl_fact
    )

    # Tests if all child_specs are used for starting children.
    Common.validate_registry_length(context, child_specs)

    # Tests redundancy and check if started children's count matches replication factor.
    Common.validate_replication(context)

    # Tests redundancy mode and check if replicated children are in passive/active mode.
    Common.validate_redundancy_mode(context)
  end

  @tag redun_strategy: :singularity
  @tag hub_id: :redunc_singulary_test
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :local},
         {Hook.registry_pid_inserted(), :local}
       ]
  test "redundancy with singularity", %{hub_id: hub_id} = context do
    child_count = 1000
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

  @tag hub_id: :divergence_test
  @tag partition_strategy: :div
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :local},
         {Hook.post_nodes_redistribution(), :global}
       ]
  test "partition divergence test",
       %{hub_id: hub_id, listed_hooks: lh} = context do
    :net_kernel.monitor_nodes(true)

    peer_to_start = 5

    new_peers =
      TestNode.start_nodes(
        peer_to_start,
        prefix: :divergence_test
      )

    peer_names = for {peer, _pid} <- new_peers, do: peer

    Bootstrap.gen_hub(context)
    |> Bootstrap.start_hubs(peer_names, lh, true)

    assert ProcessHub.is_partitioned?(hub_id) === false

    end_num = peer_to_start - 1

    Enum.reduce(peer_to_start..end_num, new_peers, fn numb, acc ->
      removed_peers = Common.stop_peers(acc, 1)
      Bag.receive_multiple(numb, Hook.post_nodes_redistribution())
      Enum.filter(acc, fn node -> !Enum.member?(removed_peers, node) end)
    end)

    assert ProcessHub.is_partitioned?(hub_id) === false

    :net_kernel.monitor_nodes(false)
  end

  @tag hub_id: :static_quroum_test
  @tag partition_strategy: :static
  @tag quorum_size: @nr_of_peers + 2
  @tag quorum_startup_confirm: true
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :local},
         {Hook.post_cluster_leave(), :local},
         {Hook.post_nodes_redistribution(), :local}
       ]
  test "static quorum with min of #{@nr_of_peers + 2} nodes",
       %{hub_id: hub_id, peer_nodes: peers, listed_hooks: lh} = context do
    :net_kernel.monitor_nodes(true)

    # We don't have enough nodes to form the cluster and startup_confirm is set `true`
    assert ProcessHub.is_partitioned?(hub_id) === true

    peer_to_start = 2
    new_peers = TestNode.start_nodes(peer_to_start, prefix: :static_quorum_test_patch1)
    peer_names = for {peer, _pid} <- new_peers, do: peer

    Bootstrap.gen_hub(context) |> Bootstrap.start_hubs(peer_names, lh, true)
    Bag.receive_multiple(peer_to_start, Hook.post_nodes_redistribution())

    # We have added #{peer_to_start} nodes so our cluster shouldn't be partitioned anymore.
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

  @tag hub_id: :dynamic_quroum_test
  @tag partition_strategy: :dynamic
  @tag quorum_size: 80
  # 1 hour
  @tag quorum_threshold_time: 3600
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :local},
         {Hook.post_cluster_leave(), :local},
         {Hook.post_nodes_redistribution(), :local}
       ]
  test "dynamic quorum with min of 70% of cluster",
       %{hub_id: hub_id, listed_hooks: lh} = context do
    :net_kernel.monitor_nodes(true)

    Bag.receive_multiple(@nr_of_peers, Hook.post_nodes_redistribution())

    assert ProcessHub.is_partitioned?(hub_id) === false

    peer_to_start = 4
    new_peers = TestNode.start_nodes(peer_to_start, prefix: :dynamic_quorum_test)
    peer_names = for {peer, _pid} <- new_peers, do: peer

    Bootstrap.gen_hub(context) |> Bootstrap.start_hubs(peer_names, lh, true)
    Bag.receive_multiple(peer_to_start, Hook.post_nodes_redistribution())

    assert ProcessHub.is_partitioned?(hub_id) === false

    removed_peers = Common.stop_peers(new_peers, 1)
    new_peers = Enum.filter(new_peers, fn node -> !Enum.member?(removed_peers, node) end)
    Bag.receive_multiple(1, Hook.post_nodes_redistribution())

    # At this point we still have 90% of cluster left.
    assert ProcessHub.is_partitioned?(hub_id) === false

    removed_peers = Common.stop_peers(new_peers, 1)
    new_peers = Enum.filter(new_peers, fn node -> !Enum.member?(removed_peers, node) end)
    Bag.receive_multiple(1, Hook.post_nodes_redistribution())

    # At this point we still have 80% of cluster left.
    assert ProcessHub.is_partitioned?(hub_id) === false

    removed_peers = Common.stop_peers(new_peers, 1)
    _new_peers = Enum.filter(new_peers, fn node -> !Enum.member?(removed_peers, node) end)
    Bag.receive_multiple(1, Hook.post_nodes_redistribution())

    # At this point we have 70% of cluster left.
    assert ProcessHub.is_partitioned?(hub_id) === true

    :net_kernel.monitor_nodes(false)
  end

  @tag migr_strategy: :cold
  @tag hub_id: :migration_coldswap_test
  @tag redun_strategy: :replication
  @tag replication_factor: 2
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :local},
         {Hook.post_cluster_leave(), :global},
         {Hook.registry_pid_inserted(), :global},
         {Hook.children_migrated(), :global}
       ]
  test "coldswap migration with replication",
       %{hub_id: hub_id, replication_factor: rf, listed_hooks: lh} = context do
    nodes_count = @nr_of_peers
    child_count = 1000
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    # Stop hubs on peer nodes before we start.
    Enum.each(Node.list(), fn node ->
      :erpc.call(node, ProcessHub.Initializer, :stop, [hub_id])
    end)

    # Confirm that hubs are stopped.
    Bag.receive_multiple(nodes_count, Hook.post_cluster_leave())

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

  @tag migr_strategy: :hot
  @tag dist_strategy: :consistent_hashing
  @tag hub_id: :migration_hotswap_test
  @tag migr_handover: true
  @tag migr_retention: 3000
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :local},
         {Hook.post_cluster_leave(), :local},
         {Hook.registry_pid_inserted(), :local},
         {Hook.registry_pid_removed(), :local},
         {Hook.post_nodes_redistribution(), :local},
         {Hook.children_migrated(), :global},
         {Hook.forwarded_migration(), :global}
       ]
  test "hotswap migration with handoff",
       %{hub_id: hub_id, listed_hooks: lh, hub: hub} = context do
    nodes_count = @nr_of_peers
    child_count = 1000
    child_specs = Bag.gen_child_specs(child_count, Atom.to_string(hub_id))

    # Node ups.
    Bag.receive_multiple(nodes_count, Hook.post_nodes_redistribution(),
      error_msg: "Post redistribution timeout"
    )

    # Stop hubs on peer nodes before we start.
    Enum.each(Node.list(), fn node ->
      :erpc.call(node, ProcessHub.Initializer, :stop, [hub_id])
    end)

    # Node downs
    Bag.receive_multiple(nodes_count, Hook.post_nodes_redistribution(),
      error_msg: "Post redistribution timeout"
    )

    # Confirm that hubs are stopped.
    Bag.receive_multiple(nodes_count, Hook.post_cluster_leave(),
      error_msg: "Cluster leave timeout"
    )

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

    # Node ups
    Bag.receive_multiple(nodes_count, Hook.post_nodes_redistribution(),
      error_msg: "Post redistribution timeout"
    )

    local_node = node()
    dist_strat = hub.distribution_strategy

    # Get all children that have been migrated.
    migrated_children =
      Enum.map(child_specs, fn child_spec ->
        {
          child_spec.id,
          ProcessHub.Strategy.Distribution.Base.belongs_to(dist_strat, hub_id, child_spec.id, 1)
          |> List.first()
        }
      end)
      |> Enum.filter(fn {_, node} ->
        local_node !== node
      end)

    Bag.receive_multiple(
      @nr_of_peers,
      {Hook.children_migrated(), Hook.forwarded_migration()},
      error_msg: "Children migration timeout"
    )

    # Validate the data.
    Enum.each(migrated_children, fn {child_id, node} ->
      pid =
        ProcessHub.child_lookup(hub_id, child_id)
        |> elem(1)
        |> Enum.find(fn {child_node, _pid} -> child_node === node end)
        |> elem(1)

      handover_data = GenServer.call(pid, {:get_value, :handoff_data})

      assert handover_data === child_id,
             "Child #{child_id} invalid data: #{inspect(handover_data)}"
    end)
  end
end
