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
