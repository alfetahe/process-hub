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

  @tag migr_strategy: :cold
  @tag hub_id: :migration_coldswap_test
  @tag redun_strategy: :replication
  @tag replication_factor: 3
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :global},
         {Hook.post_cluster_leave(), :global},
         {Hook.registry_pid_inserted(), :global},
         {Hook.children_migrated(), :global}
       ]
  test "coldswap migration with replication",
       %{hub_id: hub_id, replication_factor: rf, listed_hooks: lh, hub: hub} = context do
    nodes_count = @nr_of_peers
    child_count = 50000
    child_specs = Bag.gen_child_specs(child_count, prefix: Atom.to_string(hub_id))

    dbg("------------------------- TEST STARTING -------------------------")

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
      GenServer.call(pid, {:set_value, :handoff_data, child_spec.id})
    end)

    # Restart hubs on peer nodes and confirm they are up and running.
    Bootstrap.gen_hub(context)
    |> Bootstrap.start_hubs(Node.list(), lh, new_nodes: true)

    ring = ProcessHub.Service.Ring.get_ring(hub.storage.misc)
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
      error_msg: "Child added timeout",
      # TODO: remove.
      timeout: 50_000
    )

    Bag.receive_multiple(
      length(migrated_children) * rf,
      Hook.registry_pid_inserted(),
      error_msg: "Child added timeout",
      timeout: 50_000
    )
  end
end
