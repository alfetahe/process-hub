defmodule Test.TempTest do
  alias ProcessHub.Utility.Bag
  alias Test.Helper.Common
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

  @tag migr_strategy: :cold
  @tag hub_id: :migration_coldswap_handover_test
  @tag migr_handover: true
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :global},
         {Hook.post_cluster_leave(), :global},
         {Hook.registry_pid_inserted(), :global},
         {Hook.children_migrated(), :global},
         {Hook.coldswap_handover_delivered(), :global}
       ]
  test "coldswap migration with state handover",
       %{hub_id: hub_id, listed_hooks: lh, hub: _hub} = context do
    nodes_count = @nr_of_peers
    child_count = 1000
    child_specs = Bag.gen_child_specs(child_count, prefix: Atom.to_string(hub_id))

    {stop_hubs_time, _} = :timer.tc(fn ->
      # Stop hubs on peer nodes before we start.
      Enum.each(Node.list(), fn node ->
        :erpc.call(node, ProcessHub.Initializer, :stop, [hub_id])
      end)

      # Confirm that hubs are stopped.
      Bag.receive_multiple(nodes_count, Hook.post_cluster_leave())
    end)
    dbg({:TEST_PHASE_MS, :stop_peer_hubs, div(stop_hubs_time, 1000)})

    {start_children_time, _} = :timer.tc(fn ->
      # Start children on local node only.
      Common.sync_base_test(context, child_specs, :add)
    end)
    dbg({:TEST_PHASE_MS, :start_children_locally, div(start_children_time, 1000), child_count})

    {set_handover_time, _} = :timer.tc(fn ->
      # Add custom handover data to each child.
      Enum.each(child_specs, fn child_spec ->
        {_child_spec, [{_, pid}]} = ProcessHub.child_lookup(hub_id, child_spec.id)
        GenServer.call(pid, {:set_value, :handover_data, child_spec.id})
      end)
    end)
    dbg({:TEST_PHASE_MS, :set_handover_data, div(set_handover_time, 1000)})

    {restart_hubs_time, _} = :timer.tc(fn ->
      # Restart hubs on peer nodes - this will trigger migration.
      # Use skip_await because cluster_size calculation is wrong after hub restart
      Bootstrap.gen_hub(context)
      |> Bootstrap.start_hubs(Node.list(), lh, new_nodes: true, skip_await: true)
    end)
    dbg({:TEST_PHASE_MS, :restart_peer_hubs, div(restart_hubs_time, 1000)})

    {wait_joins_time, _} = :timer.tc(fn ->
      # Wait for all peer nodes to join the cluster
      Bag.receive_multiple(
        nodes_count,
        Hook.post_cluster_join(),
        error_msg: "Cluster join timeout"
      )
    end)
    dbg({:TEST_PHASE_MS, :wait_cluster_joins, div(wait_joins_time, 1000)})

    # Get fresh hub to get updated ring after restart
    fresh_hub = ProcessHub.Coordinator.get_hub(hub_id)
    ring = ProcessHub.Service.Ring.get_ring(fresh_hub.storage.misc)
    local_node = node()

    # Get all children that should migrate to other nodes.
    migrated_children =
      Enum.map(child_specs, fn child_spec ->
        {child_spec.id, ProcessHub.Service.Ring.key_to_nodes(ring, child_spec.id, 1)}
      end)
      |> Enum.filter(fn {_, nodes} ->
        !Enum.member?(nodes, local_node)
      end)

    {wait_migrations_time, _} = :timer.tc(fn ->
      # Wait for migrations to complete.
      if length(migrated_children) > 0 do
        Bag.receive_multiple(
          length(migrated_children),
          Hook.registry_pid_inserted(),
          error_msg: "Child migration timeout"
        )
      end
    end)
    dbg({:TEST_PHASE_MS, :wait_migrations, div(wait_migrations_time, 1000), length(migrated_children)})

    {wait_handover_time, _} = :timer.tc(fn ->
      if length(migrated_children) > 0 do
        # Wait for state handover to be delivered.
        Bag.receive_multiple(
          length(migrated_children),
          Hook.coldswap_handover_delivered(),
          error_msg: "Handover delivery timeout"
        )
      end
    end)
    dbg({:TEST_PHASE_MS, :wait_handover_delivery, div(wait_handover_time, 1000)})

    {validate_time, validated_count} = :timer.tc(fn ->
      # Validate that handover data was transferred to migrated children.
      # We check children that migrated to remote nodes by calling via :erpc
      Enum.reduce(migrated_children, 0, fn {child_id, nodes}, count ->
        target_node = List.first(nodes)

        case ProcessHub.child_lookup(hub_id, child_id) do
          {_child_spec, node_pids} when node_pids != [] ->
            # Find the pid on the target node
            case Enum.find(node_pids, fn {n, _pid} -> n === target_node end) do
              {^target_node, pid} ->
                # Call the remote process via :erpc
                handover_data =
                  :erpc.call(target_node, GenServer, :call, [pid, {:get_value, :handover_data}])

                assert handover_data === child_id,
                       "Child #{child_id} invalid handover data: #{inspect(handover_data)}"

                count + 1

              nil ->
                # Process not on expected node, skip
                count
            end

          _ ->
            count
        end
      end)
    end)
    dbg({:TEST_PHASE_MS, :validate_handover, div(validate_time, 1000), validated_count})

    # Ensure we validated at least some children
    assert validated_count > 0, "No migrated children were validated"
  end
end
