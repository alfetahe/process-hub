defmodule Test.Service.ClusterTest do
  alias ProcessHub.Service.Cluster
  alias Test.Helper.TestNode
  alias Test.Helper.Bootstrap
  alias Test.Helper.Common
  alias ProcessHub.Utility.Bag

  use ProcessHub.Constant.Event
  use ExUnit.Case

  @hub_id :cluster_test

  setup %{} do
    local_node = node()
    context = Test.Helper.SetupHelper.setup_base(%{}, @hub_id)

    on_exit(fn ->
      ProcessHub.Service.Storage.insert(context.hub.storage.misc, :hub_nodes, [local_node])
    end)

    context
  end

  test "nodes", %{hub: hub} = _context do
    assert Cluster.nodes(hub.storage.misc) === []
    assert Cluster.nodes(hub.storage.misc, [:include_local]) === [node()]
  end

  test "add confirmed node", %{hub: hub} = _context do
    local_node = node()

    assert Cluster.add_hub_node(hub.storage.misc, :new) === [local_node, :new]
    assert Cluster.add_hub_node(hub.storage.misc, :dupl) === [local_node, :new, :dupl]
    assert Cluster.add_hub_node(hub.storage.misc, :dupl) === [local_node, :new, :dupl]
    assert Cluster.add_hub_node(hub.storage.misc, :one) === [local_node, :new, :dupl, :one]
    assert Cluster.add_hub_node(hub.storage.misc, :two) === [local_node, :new, :dupl, :one, :two]

    assert ProcessHub.Service.Storage.get(hub.storage.misc, :hub_nodes) === [
             local_node,
             :new,
             :dupl,
             :one,
             :two
           ]
  end

  test "rem confirmed node", %{hub: hub} = _context do
    local_node = node()
    nodes = [:one, :two, :three, :four]
    Enum.each(nodes, fn node -> Cluster.add_hub_node(hub.storage.misc, node) end)
    assert ProcessHub.Service.Storage.get(hub.storage.misc, :hub_nodes) === [local_node | nodes]

    assert Cluster.rem_hub_node(hub.storage.misc, :one) === [local_node, :two, :three, :four]
    assert Cluster.rem_hub_node(hub.storage.misc, :two) === [local_node, :three, :four]
    assert Cluster.rem_hub_node(hub.storage.misc, :three) === [local_node, :four]
    assert Cluster.rem_hub_node(hub.storage.misc, :four) === [local_node]

    assert ProcessHub.Service.Storage.get(hub.storage.misc, :hub_nodes) === [local_node]
  end

  test "is new node", _context do
    assert Cluster.new_node?([:existing, :second], :existing) === false
    assert Cluster.new_node?([:existing, :second], :noexisting) === true
    assert Cluster.new_node?([], :noexisting) === true
  end

  test "handle_node_down removes nodes and dispatches hooks", %{hub: hub} = _context do
    test_pid = self()

    # Register hook to capture pre_cluster_leave dispatches
    pre_leave_handler = %ProcessHub.Service.HookManager{
      id: :cluster_test_node_down_pre,
      m: ProcessHub.Utility.Bag,
      f: :hook_erlang_send,
      a: [:_, test_pid, :pre_leave_hook]
    }

    post_leave_handler = %ProcessHub.Service.HookManager{
      id: :cluster_test_node_down_post,
      m: ProcessHub.Utility.Bag,
      f: :hook_erlang_send,
      a: [:_, test_pid, :post_leave_hook]
    }

    ProcessHub.Service.HookManager.register_handler(
      hub.storage.hook,
      ProcessHub.Constant.Hook.pre_cluster_leave(),
      pre_leave_handler
    )

    ProcessHub.Service.HookManager.register_handler(
      hub.storage.hook,
      ProcessHub.Constant.Hook.post_cluster_leave(),
      post_leave_handler
    )

    # Add some nodes first
    Cluster.add_hub_node(hub.storage.misc, :down_node1)
    Cluster.add_hub_node(hub.storage.misc, :down_node2)

    # Verify nodes are present
    nodes_before = Cluster.nodes(hub.storage.misc, [:include_local])
    assert :down_node1 in nodes_before
    assert :down_node2 in nodes_before

    # Call handle_node_down
    Cluster.handle_node_down(%{removed_nodes: [:down_node1, :down_node2], hub: hub})

    # Verify nodes were removed from storage
    nodes_after = Cluster.nodes(hub.storage.misc, [:include_local])
    refute :down_node1 in nodes_after
    refute :down_node2 in nodes_after

    # Verify pre_cluster_leave hooks were dispatched for each removed node
    assert_receive {:pre_leave_hook, :down_node1}, 1000
    assert_receive {:pre_leave_hook, :down_node2}, 1000

    # Verify post_cluster_leave hooks were dispatched
    assert_receive {:post_leave_hook, %{removed_node: :down_node1}}, 1000
    assert_receive {:post_leave_hook, %{removed_node: :down_node2}}, 1000
  end

  test "handle_node_up adds nodes and dispatches hooks", %{hub: hub} = _context do
    test_pid = self()

    # Register hooks to capture dispatches
    pre_join_handler = %ProcessHub.Service.HookManager{
      id: :cluster_test_node_up_pre,
      m: ProcessHub.Utility.Bag,
      f: :hook_erlang_send,
      a: [:_, test_pid, :pre_join_hook]
    }

    post_join_handler = %ProcessHub.Service.HookManager{
      id: :cluster_test_node_up_post,
      m: ProcessHub.Utility.Bag,
      f: :hook_erlang_send,
      a: [:_, test_pid, :post_join_hook]
    }

    ProcessHub.Service.HookManager.register_handler(
      hub.storage.hook,
      ProcessHub.Constant.Hook.pre_cluster_join(),
      pre_join_handler
    )

    ProcessHub.Service.HookManager.register_handler(
      hub.storage.hook,
      ProcessHub.Constant.Hook.post_cluster_join(),
      post_join_handler
    )

    # Verify nodes are not yet in the cluster
    nodes_before = Cluster.nodes(hub.storage.misc, [:include_local])
    refute :up_node1 in nodes_before

    # Call handle_node_up
    Cluster.handle_node_up(%{joined_nodes: [:up_node1, :up_node2], hub: hub})

    # Verify nodes were added to storage
    nodes_after = Cluster.nodes(hub.storage.misc, [:include_local])
    assert :up_node1 in nodes_after
    assert :up_node2 in nodes_after

    # Verify pre_cluster_join hooks were dispatched for each joining node
    assert_receive {:pre_join_hook, :up_node1}, 1000
    assert_receive {:pre_join_hook, :up_node2}, 1000

    # Verify post_cluster_join hooks were dispatched
    assert_receive {:post_join_hook, %{joined_node: :up_node1}}, 1000
    assert_receive {:post_join_hook, %{joined_node: :up_node2}}, 1000
  end

  test "handle_node_down with single node", %{hub: hub} = _context do
    Cluster.add_hub_node(hub.storage.misc, :single_down)

    assert :single_down in Cluster.nodes(hub.storage.misc, [:include_local])

    Cluster.handle_node_down(%{removed_nodes: [:single_down], hub: hub})

    refute :single_down in Cluster.nodes(hub.storage.misc, [:include_local])
  end

  test "handle_node_down with non-existent node does not crash", %{hub: hub} = _context do
    # Should not crash even though the node was never added
    Cluster.handle_node_down(%{removed_nodes: [:never_existed], hub: hub})

    # Local node should still be present
    assert node() in Cluster.nodes(hub.storage.misc, [:include_local])
  end

  test "promote_to_node returns error when node not alive", %{hub: hub} = _context do
    # On a non-distributed node (Node.alive?() == false), promote_to_node should return error
    # In test mode, Node.alive?() depends on whether tests run with --name flag
    result = Cluster.promote_to_node(hub, :test_node_name)

    case Node.alive?() do
      false -> assert result == {:error, :not_alive}
      true -> assert result == :ok
    end
  end

  test "promote to node", _context do
    hub_id = :promote_test
    new_node_name = :promote_node_new

    [{peer_node, peer_pid}] = TestNode.start_nodes(1, prefix: :promote)
    hub = Bootstrap.gen_hub(%{hub_id: hub_id})
    Bootstrap.start_hubs(hub, [peer_node], [], new_nodes: true)

    child_specs = Bag.gen_child_specs(10, prefix: Atom.to_string(hub_id))

    :erpc.call(peer_node, Common, :sync_start, [hub_id, child_specs])
    :erpc.call(peer_node, ProcessHub, :process_list, [hub_id, :global])
    :erpc.call(peer_node, ProcessHub, :promote_to_node, [hub_id, new_node_name])

    children = :erpc.call(peer_node, ProcessHub, :process_list, [hub_id, :global])
    hub_nodes = :erpc.call(peer_node, ProcessHub, :nodes, [hub_id, [:include_local]])

    children_result =
      Enum.all?(children, fn {_child_id, [{n, _p}]} ->
        n === new_node_name
      end)

    assert children_result == true
    assert hub_nodes === [new_node_name]

    :peer.stop(peer_pid)
  end
end
