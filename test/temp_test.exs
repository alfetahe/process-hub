defmodule Test.TempTest do
  # alias Test.Helper.TestNode
  alias ProcessHub.Utility.Bag
  alias Test.Helper.Common
  alias Test.Helper.Bootstrap
  alias ProcessHub.Constant.Hook

  use ExUnit.Case, async: false

  # Total nr of nodes to start (without the main node)
  @nr_of_peers 10

  setup_all context do
    context = Map.put(context, :validate_metadata, false)

    Map.merge(Test.Helper.Bootstrap.init_nodes(@nr_of_peers), context)
  end

  setup context do
    Test.Helper.Bootstrap.bootstrap(context)
  end

  @tag migr_strategy: :hot
  @tag dist_strategy: :consistent_hashing
  @tag hub_id: :migration_hotswap_test
  @tag migr_handover: true
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :global},
         {Hook.post_cluster_leave(), :local},
         {Hook.registry_pid_inserted(), :local},
         {Hook.registry_pid_removed(), :local},
         {Hook.post_nodes_redistribution(), :local},
         {Hook.children_migrated(), :global},
         {Hook.forwarded_migration(), :global},
         {Hook.hotswap_handover_delivered(), :local}
       ]
  test "hotswap migration with handoff",
       %{hub_id: hub_id, listed_hooks: lh, hub_conf: hub_conf, hub: hub} = context do
    nodes_count = @nr_of_peers
    child_count = 50000

    child_specs =
      Bag.gen_child_specs(
        child_count,
        prefix: Atom.to_string(hub_id),
        id_type: :string
      )

    # Cluster is already formed - start_hubs waits for post_cluster_join
    # No additional wait needed here

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
    Bootstrap.gen_hub(context)
    |> Bootstrap.start_hubs(Node.list(), lh, new_nodes: true)

    # Wait for all hotswap handovers to complete (migration completion signal)
    if length(migrated_children) > 0 do
      Bag.receive_multiple(
        length(migrated_children),
        Hook.hotswap_handover_delivered(),
        error_msg: "Hotswap handover timeout",
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

  # @tag migr_strategy: :cold
  # @tag hub_id: :migration_coldswap_test
  # @tag redun_strategy: :replication
  # @tag replication_factor: 3
  # @tag listed_hooks: [
  #        {Hook.post_cluster_join(), :global},
  #        {Hook.post_cluster_leave(), :global},
  #        {Hook.registry_pid_inserted(), :global},
  #        {Hook.children_migrated(), :global}
  #      ]
  # test "coldswap migration with replication",
  #      %{hub_id: hub_id, replication_factor: rf, listed_hooks: lh, hub: hub} = context do
  #   nodes_count = @nr_of_peers
  #   child_count = 10000
  #   child_specs = Bag.gen_child_specs(child_count, prefix: Atom.to_string(hub_id))

  #   dbg("------------------------- TEST STARTING -------------------------")

  #   # Stop hubs on peer nodes before we start.
  #   Enum.each(Node.list(), fn node ->
  #     :erpc.call(node, ProcessHub.Initializer, :stop, [hub_id])
  #   end)

  #   # Confirm that hubs are stopped.
  #   Bag.receive_multiple(nodes_count, Hook.post_cluster_leave())

  #   # Starts children.
  #   Common.sync_base_test(context, child_specs, :add)

  #   # Add custom data to children.
  #   Enum.each(child_specs, fn child_spec ->
  #     {_child_spec, [{_, pid}]} = ProcessHub.child_lookup(hub_id, child_spec.id)
  #     GenServer.call(pid, {:set_value, :handoff_data, child_spec.id})
  #   end)

  #   # Restart hubs on peer nodes and confirm they are up and running.
  #   Bootstrap.gen_hub(context)
  #   |> Bootstrap.start_hubs(Node.list(), lh, new_nodes: true)

  #   ring = ProcessHub.Service.Ring.get_ring(hub.storage.misc)
  #   local_node = node()

  #   # Get all children that have been migrated. Meaning the old ones are killed
  #   # and spawned on other nodes. We can check all that no longer live on the main
  #   # node.
  #   migrated_children =
  #     Enum.map(child_specs, fn child_spec ->
  #       {child_spec.id, ProcessHub.Service.Ring.key_to_nodes(ring, child_spec.id, rf)}
  #     end)
  #     |> Enum.filter(fn {_, nodes} ->
  #       !Enum.member?(nodes, local_node)
  #     end)

  #   # Confirm that all migrated children have been updated.
  #   Bag.receive_multiple(
  #     length(migrated_children),
  #     Hook.registry_pid_inserted(),
  #     error_msg: "Child added timeout",
  #     # TODO: remove.
  #     timeout: 50_000
  #   )

  #   Bag.receive_multiple(
  #     length(migrated_children) * rf,
  #     Hook.registry_pid_inserted(),
  #     error_msg: "Child added timeout",
  #     timeout: 50_000
  #   )
  # end
end
