defmodule Test.TempTest do
  alias Test.Helper.TestNode
  alias Test.Helper.Common
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Constant.Hook
  alias Test.Helper.Bootstrap

  use ExUnit.Case, async: false

  # Total nr of nodes to start (without the main node)
  @nr_of_peers 5

  # Number of new nodes to add during scale-up
  @peers_to_start 3

  # Number of children to start
  @child_count 10000

  setup_all context do
    context = Map.put(context, :validate_metadata, false)

    Map.merge(Bootstrap.init_nodes(@nr_of_peers), context)
  end

  setup context do
    Bootstrap.bootstrap(context)
  end

  # @tag hub_id: :pubsub_start_rem_test
  # @tag sync_strategy: :pubsub
  # @tag validate_metadata: true
  # @tag listed_hooks: [
  #        {Hook.post_cluster_join(), :global},
  #        {Hook.registry_pid_inserted(), :global},
  #        {Hook.registry_pid_removed(), :global}
  #      ]
  # test "pubsub children starting and removing", %{hub_id: hub_id} = context do
  #   child_count = 30000
  #   child_specs = Bag.gen_child_specs(child_count, prefix: Atom.to_string(hub_id))

  #   # Starts children on all nodes.
  #   Common.sync_base_test(context, child_specs, :add, scope: :global)

  #   # Tests if all child_specs are used for starting children.
  #   Common.validate_registry_length(context, child_specs)

  #   # Tests if all child_specs are started on all nodes.
  #   Common.validate_started_children(context, child_specs)

  #   # Tests children adding and syncing.
  #   Common.validate_sync(context)

  #   # Stops children on all nodes.
  #   Common.sync_base_test(context, child_specs, :rem, scope: :global)

  #   # Tests children removing and syncing.
  #   Common.validate_sync(context)
  # end
end
