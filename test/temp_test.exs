defmodule Test.TempTest do
  alias Test.Helper.TestNode
  alias ProcessHub.Utility.Bag
  alias Test.Helper.Common
  alias ProcessHub.Constant.Hook
  alias Test.Helper.Bootstrap

  use ExUnit.Case, async: false

  # Total nr of nodes to start (without the main node)
  @nr_of_peers 5

  # Number of new nodes to add during scale-up
  @peers_to_start 3

  # Number of children to start
  @child_count 1000

  setup_all context do
    context = Map.put(context, :validate_metadata, false)

    Map.merge(Bootstrap.init_nodes(@nr_of_peers), context)
  end

  setup context do
    Bootstrap.bootstrap(context)
  end

  @tag migr_strategy: :cold
  @tag dist_strategy: :consistent_hashing
  @tag hub_id: :migration_coldswap_test
  @tag migr_handover: true
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :global},
         {Hook.post_cluster_leave(), :local},
         {Hook.registry_pid_inserted(), :local},
         {Hook.registry_pid_removed(), :local},
         {Hook.post_nodes_redistribution(), :local},
         {Hook.children_migrated(), :global},
         {Hook.forwarded_migration(), :global},
         {Hook.handover_delivered(), :local}
       ]
  test "coldswap migration with handoff",
       %{hub_id: hub_id, listed_hooks: lh, hub_conf: hub_conf, hub: hub} = context do
    nodes_count = @nr_of_peers
    child_count = 10000

    child_specs =
      Bag.gen_child_specs(
        child_count,
        prefix: Atom.to_string(hub_id),
        id_type: :string
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
      GenServer.call(pid, {:set_value, :handoff_data, child_spec.id})
    end)

    # Calculate which children will be migrated BEFORE restarting hubs
    local_node = node()
    dist_strat = hub_conf.distribution_strategy
    child_ids = Enum.map(child_specs, & &1.id)

    migrated_children =
      dist_strat
      |> ProcessHub.Strategy.Distribution.Base.belongs_to(hub, child_ids, 1)
      |> Enum.map(fn {child_id, nodes} -> {child_id, List.first(nodes)} end)
      |> Enum.filter(fn {_, node} -> node !== local_node end)

    # Restart hubs on peer nodes and confirm they are up and running.
    # Use skip_await because cluster_size calculation is wrong after hub restart
    Bootstrap.gen_hub(context)
    |> Bootstrap.start_hubs(Node.list(), lh, new_nodes: true, skip_await: true)

    # Wait for all handover deliveries to complete (migration completion signal)
    migrated_child_ids = Enum.map(migrated_children, fn {child_id, _node} -> child_id end)

    if length(migrated_child_ids) > 0 do
      Bag.await_child_ids(
        Hook.handover_delivered(),
        migrated_child_ids,
        error_msg: "Handover delivery timeout",
        timeout: 60_000
      )
    end

    # Validate the data.
    Enum.each(migrated_children, fn {child_id, node} ->
      pid =
        ProcessHub.child_lookup(hub_id, child_id)
        |> elem(1)
        |> Enum.find(fn {child_node, _pid} -> child_node === node end)
        |> elem(1)

      handover_data = GenServer.call(pid, {:get_value, :handoff_data})

      assert handover_data === child_id,
             "Child #{child_id} invalid data: #{inspect(handover_data)} with pid #{inspect(pid)}"
    end)
  end

  # @tag redun_strategy: :replication
  # @tag migr_strategy: :cold
  # @tag hub_id: :redunc_activ_pass_test
  # @tag replication_model: :active_passive
  # @tag validate_metadata: true
  # @tag replication_factor: 3
  # @tag cluster_event_debounce: 1000
  # @tag listed_hooks: [
  #        {Hook.post_cluster_join(), :global},
  #        {Hook.registry_pid_inserted(), :global},
  #        {Hook.registry_pid_removed(), :global},
  #        {Hook.post_nodes_redistribution(), :global}
  #      ]
  # test "replication factor and mode", %{hub_id: hub_id, replication_factor: rf} = context do
  #   :net_kernel.monitor_nodes(true)

  #   child_specs = Bag.gen_child_specs(@child_count, prefix: Atom.to_string(hub_id))

  #   # Starts children on all nodes.
  #   Common.sync_base_test(context, child_specs, :add, scope: :global, replication_factor: rf)

  #   # Scale up: start more nodes and verify replication is maintained
  #   new_peers = TestNode.start_nodes(@peers_to_start, prefix: :redunc_activ_pass_test)
  #   peer_names = for {peer, _pid} <- new_peers, do: peer

  #   Bootstrap.gen_hub(context)
  #   |> Bootstrap.start_hubs(peer_names, context.listed_hooks, new_nodes: true, skip_await: true)

  #   # Wait until registry is stable (all children have expected nodes)
  #   Common.await_registry_stable(hub_id, child_specs, rf)

  #   # Tests if all child_specs are used for starting children.
  #   Common.validate_registry_length(context, child_specs)

  #   # Tests redundancy and check if started children's count matches replication factor.
  #   Common.validate_replication(context)

  #   # Now scale down back to original nodes and see if replication is still maintained
  #   Enum.reduce(1..@peers_to_start, new_peers, fn _x, acc ->
  #     removed_peers = Common.stop_peers(acc, 1)
  #     remaining = Enum.filter(acc, fn node -> !Enum.member?(removed_peers, node) end)

  #     # Wait until registry is stable (all children have expected nodes)
  #     Common.await_registry_stable(hub_id, child_specs, rf)

  #     remaining
  #   end)

  #   Common.validate_registry_length(context, child_specs)
  #   Common.validate_replication(context)
  #   Common.validate_redundancy_mode(context)

  #   :net_kernel.monitor_nodes(false)
  # end
end
