defmodule Test.TempTest do
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

  @tag hub_id: :migration_autonomous_test
  @tag migr_strategy: :autonomous
  @tag dist_strategy: :consistent_hashing
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :global},
         {Hook.post_cluster_leave(), :local},
         {Hook.registry_pid_inserted(), :global},
         {Hook.registry_pid_removed(), :global}
       ]
  test "migration autonomous contraction", %{hub_id: hub_id} = context do
    child_count = 1000
    child_specs = Bag.gen_child_specs(child_count, prefix: Atom.to_string(hub_id))

    Common.sync_base_test(context, child_specs, :add, scope: :global)

    hub = ProcessHub.Coordinator.get_hub(hub_id)

    dist_strat =
      ProcessHub.Service.Storage.get(hub.storage.misc, ProcessHub.Constant.StorageKey.strdist())

    child_ids = Enum.map(child_specs, & &1.id)
    stopped_node = Node.list() |> List.first()

    migrated_children_count =
      dist_strat
      |> ProcessHub.Strategy.Distribution.Base.belongs_to(hub, child_ids, 1)
      |> Enum.count(fn {_child_id, [node]} -> node === stopped_node end)

    # Stop hub on one peer node.
    :erpc.call(stopped_node, ProcessHub.Initializer, :stop, [hub_id])

    # Confirm that the hub is stopped.
    Bag.await_cluster_leave(1, scope: :local)

    Bag.receive_multiple(
      migrated_children_count,
      Hook.registry_pid_inserted(),
      error_msg: "Children migration timeout"
    )

    # Wait until registry stabilizes: all children placed according to updated ring.
    Common.await_registry_stable(hub_id, child_specs, 1, timeout: 15_000)
  end
end
