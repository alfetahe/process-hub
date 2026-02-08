defmodule Test.Service.ClusterTest do
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook
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

  test "process_hub_join dispatches hooks with correct node data", %{hub: hub} = _context do
    test_pid = self()

    handler = %HookManager{
      id: :cluster_test_hub_join_hook,
      m: __MODULE__,
      f: :send_hook_data,
      a: [test_pid, :hub_join, :_]
    }

    HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_join(), handler)

    # Add multiple new nodes
    Cluster.process_hub_join(hub, [:new_node1, :new_node2, :new_node3])

    # Verify hook is called with each specific node name
    assert_receive {:hook_called, :hub_join, :new_node1}, 1000
    assert_receive {:hook_called, :hub_join, :new_node2}, 1000
    assert_receive {:hook_called, :hub_join, :new_node3}, 1000

    # Verify no extra hook calls
    refute_receive {:hook_called, :hub_join, _}, 100
  end

  test "process_hub_join filters local node and existing nodes", %{hub: hub} = _context do
    local_node = node()
    test_pid = self()

    handler = %HookManager{
      id: :cluster_test_hub_join_filter,
      m: __MODULE__,
      f: :send_hook_data,
      a: [test_pid, :hub_join_filter, :_]
    }

    HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_join(), handler)

    # Add a node to simulate existing node
    Cluster.add_hub_node(hub.storage.misc, :existing_node)

    # process_hub_join should filter out local node and existing nodes
    # Only :truly_new_node should trigger hook
    result = Cluster.process_hub_join(hub, [local_node, :existing_node, :truly_new_node])

    assert result.hub_id === hub.hub_id

    # Only the truly new node should trigger hook
    assert_receive {:hook_called, :hub_join_filter, :truly_new_node}, 1000

    # Verify only one hook call (no extra calls for filtered nodes)
    refute_receive {:hook_called, :hub_join_filter, _}, 100
  end

  test "process_node_down_batch dispatches hook for single node", %{hub: hub} = _context do
    test_pid = self()

    handler = %HookManager{
      id: :cluster_test_node_down_hook,
      m: __MODULE__,
      f: :send_hook_data,
      a: [test_pid, :node_down, :_]
    }

    HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_leave(), handler)

    # Add the node first so it can be "removed"
    Cluster.add_hub_node(hub.storage.misc, :node_to_remove)

    # process_node_down_batch should dispatch the hook with the node name
    result = Cluster.process_node_down_batch(hub, [:node_to_remove])

    assert result.hub_id === hub.hub_id

    # Verify the exact node passed to hook matches expected
    assert_receive {:hook_called, :node_down, :node_to_remove}, 1000
  end

  test "process_node_down_batch ignores nodes not in hub", %{hub: hub} = _context do
    test_pid = self()

    handler = %HookManager{
      id: :cluster_test_node_down_ignore,
      m: __MODULE__,
      f: :send_hook_data,
      a: [test_pid, :node_down_ignore, :_]
    }

    HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_leave(), handler)

    # Try to remove a node that doesn't exist in the hub
    result = Cluster.process_node_down_batch(hub, [:non_existent_node])

    assert result.hub_id === hub.hub_id
    refute_receive {:hook_called, :node_down_ignore, _}, 100
  end

  test "process_node_down_batch dispatches hooks with correct node data",
       %{hub: hub} = _context do
    test_pid = self()

    handler = %HookManager{
      id: :cluster_test_batch_down_hook,
      m: __MODULE__,
      f: :send_hook_data,
      a: [test_pid, :batch_down, :_]
    }

    HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_leave(), handler)

    # Add multiple nodes
    Cluster.add_hub_node(hub.storage.misc, :batch_node1)
    Cluster.add_hub_node(hub.storage.misc, :batch_node2)
    Cluster.add_hub_node(hub.storage.misc, :batch_node3)

    # Process batch with some valid and one invalid node
    result = Cluster.process_node_down_batch(hub, [:batch_node1, :batch_node2, :non_existent])

    assert result.hub_id === hub.hub_id

    # Verify each valid node receives its own hook call with correct data
    assert_receive {:hook_called, :batch_down, :batch_node1}, 1000
    assert_receive {:hook_called, :batch_down, :batch_node2}, 1000

    # Invalid nodes don't trigger hooks
    refute_receive {:hook_called, :batch_down, :non_existent}, 100
  end

  test "process_node_down_batch handles all nodes in batch", %{hub: hub} = _context do
    test_pid = self()

    handler = %HookManager{
      id: :cluster_test_batch_all,
      m: __MODULE__,
      f: :send_hook_data,
      a: [test_pid, :batch_all, :_]
    }

    HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_leave(), handler)

    # Add multiple nodes
    Cluster.add_hub_node(hub.storage.misc, :all_node1)
    Cluster.add_hub_node(hub.storage.misc, :all_node2)
    Cluster.add_hub_node(hub.storage.misc, :all_node3)
    Cluster.add_hub_node(hub.storage.misc, :all_node4)

    # Process batch with all valid nodes
    result =
      Cluster.process_node_down_batch(hub, [:all_node1, :all_node2, :all_node3, :all_node4])

    assert result.hub_id === hub.hub_id

    # Verify all hooks dispatched with correct node names
    assert_receive {:hook_called, :batch_all, :all_node1}, 1000
    assert_receive {:hook_called, :batch_all, :all_node2}, 1000
    assert_receive {:hook_called, :batch_all, :all_node3}, 1000
    assert_receive {:hook_called, :batch_all, :all_node4}, 1000

    # Verify no extra hook calls
    refute_receive {:hook_called, :batch_all, _}, 100
  end

  test "process_node_down_batch ignores empty valid nodes list", %{hub: hub} = _context do
    test_pid = self()

    handler = %HookManager{
      id: :cluster_test_batch_empty,
      m: __MODULE__,
      f: :send_hook_data,
      a: [test_pid, :batch_empty, :_]
    }

    HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_leave(), handler)

    # Try to remove nodes that don't exist
    result = Cluster.process_node_down_batch(hub, [:non_existent1, :non_existent2])

    assert result.hub_id === hub.hub_id
    refute_receive {:hook_called, :batch_empty, _}, 100
  end

  # Helper function to send hook data with a tag
  def send_hook_data(pid, tag, node_data) do
    send(pid, {:hook_called, tag, node_data})
  end
end
