defmodule Test.Service.ClusterTest do
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Utility.Name

  use ProcessHub.Constant.Event
  use ExUnit.Case

  @hub_id :cluster_test

  setup %{} do
    local_node = node()

    exit_fun = fn ->
      ProcessHub.Service.LocalStorage.insert(@hub_id, :hub_nodes, [local_node])
    end

    Test.Helper.SetupHelper.setup_base(%{}, @hub_id, [exit_fun])
  end

  test "nodes", %{hub_id: hub_id} = _context do
    assert Cluster.nodes(hub_id) === []
    assert Cluster.nodes(hub_id, [:include_local]) === [node()]
  end

  test "add confirmed node", _context do
    local_node = node()

    assert Cluster.add_hub_node(@hub_id, :new) === [local_node, :new]
    assert Cluster.add_hub_node(@hub_id, :dupl) === [local_node, :new, :dupl]
    assert Cluster.add_hub_node(@hub_id, :dupl) === [local_node, :new, :dupl]
    assert Cluster.add_hub_node(@hub_id, :one) === [local_node, :new, :dupl, :one]
    assert Cluster.add_hub_node(@hub_id, :two) === [local_node, :new, :dupl, :one, :two]

    assert ProcessHub.Service.LocalStorage.get(@hub_id, :hub_nodes) === [
             local_node,
             :new,
             :dupl,
             :one,
             :two
           ]
  end

  test "rem confirmed node", _context do
    local_node = node()
    nodes = [:one, :two, :three, :four]
    Enum.each(nodes, fn node -> Cluster.add_hub_node(@hub_id, node) end)
    assert ProcessHub.Service.LocalStorage.get(@hub_id, :hub_nodes) === [local_node | nodes]

    assert Cluster.rem_hub_node(@hub_id, :one) === [local_node, :two, :three, :four]
    assert Cluster.rem_hub_node(@hub_id, :two) === [local_node, :three, :four]
    assert Cluster.rem_hub_node(@hub_id, :three) === [local_node, :four]
    assert Cluster.rem_hub_node(@hub_id, :four) === [local_node]

    assert ProcessHub.Service.LocalStorage.get(@hub_id, :hub_nodes) === [local_node]
  end

  test "is new node", _context do
    assert Cluster.new_node?([:existing, :second], :existing) === false
    assert Cluster.new_node?([:existing, :second], :noexisting) === true
    assert Cluster.new_node?([], :noexisting) === true
  end

  test "propagate self", %{hub_id: hub_id} = _context do
    send(Name.coordinator(hub_id), {@event_cluster_leave, node()})
    assert Cluster.nodes(hub_id) === []
    assert Cluster.propagate_self(hub_id, node())
    Process.sleep(10)
    assert Cluster.nodes(hub_id, [:include_local]) === [node()]
  end
end
