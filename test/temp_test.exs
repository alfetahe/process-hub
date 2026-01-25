defmodule Test.TempTest do
  alias Test.Helper.TestNode
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

  @tag redun_strategy: :replication
  @tag migr_strategy: :cold
  @tag hub_id: :redunc_activ_pass_test
  @tag replication_model: :active_passive
  @tag validate_metadata: true
  @tag replication_factor: 3
  @tag listed_hooks: [
         {Hook.post_cluster_join(), :global},
         {Hook.registry_pid_inserted(), :global},
         {Hook.registry_pid_removed(), :global},
         {Hook.post_nodes_redistribution(), :global}
       ]
  test "replication factor and mode", %{hub_id: hub_id, replication_factor: rf} = context do
    :net_kernel.monitor_nodes(true)

    child_count = 1000
    child_specs = Bag.gen_child_specs(child_count, prefix: Atom.to_string(hub_id))

    dbg("------------------- STARTING TEST -------------------")

    # Starts children on all nodes.
    Common.sync_base_test(context, child_specs, :add, scope: :global, replication_factor: rf)

    dbg("------------------- STARTING ADDITIONAL NODES -------------------")

    # Now let's start few more nodes and see if replication is maintained
    peer_to_start = @nr_of_peers
    new_peers = TestNode.start_nodes(peer_to_start, prefix: :redunc_activ_pass_test)
    peer_names = for {peer, _pid} <- new_peers, do: peer

    # Use skip_await to avoid message counting issues during complex scale-up
    Bootstrap.gen_hub(context)
    |> Bootstrap.start_hubs(peer_names, context.listed_hooks, new_nodes: true, skip_await: true)

    # TODO: replace with hooks.
    Process.sleep(1000)

    # Tests if all child_specs are used for starting children.
    Common.validate_registry_length(context, child_specs)

    # Tests redundancy and check if started children's count matches replication factor.
    Common.validate_replication(context)

    # Now scale down back to original nodes and see if replication is still maintained
    # Wait for stability after each node removal to allow redistribution to complete
    Enum.reduce(1..peer_to_start, new_peers, fn _x, acc ->
      removed_peers = Common.stop_peers(acc, 1)
      Enum.filter(acc, fn node -> !Enum.member?(removed_peers, node) end)
    end)

    # TODO: replace with hooks.
    Process.sleep(1000)

    Common.validate_registry_length(context, child_specs)
    Common.validate_replication(context)
    Common.validate_redundancy_mode(context)

    :net_kernel.monitor_nodes(false)
  end
end
