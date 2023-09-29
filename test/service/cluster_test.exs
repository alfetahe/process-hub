defmodule Test.Service.ClusterTest do
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Utility.Name

  use ProcessHub.Constant.Event
  use ExUnit.Case

  setup_all %{} do
    Test.Helper.SetupHelper.setup_base(%{}, :cluster_test)
  end

  test "nodes", %{hub_id: hub_id} = _context do
    assert Cluster.nodes(hub_id) === []
    assert Cluster.nodes(hub_id, [:include_local]) === [node()]
  end

  test "add confirmed node", _context do
    assert Cluster.add_cluster_node([], :new) === [:new]
    assert Cluster.add_cluster_node([:dupl], :dupl) === [:dupl]
    assert Cluster.add_cluster_node([:one, :two, :three], :three) === [:one, :two, :three]
    assert Cluster.add_cluster_node([:one, :two, :three], :four) === [:one, :two, :three, :four]
  end

  test "rem confirmed node", _context do
    assert Cluster.rem_cluster_node([], :new) === []
    assert Cluster.rem_cluster_node([:dupl], :dupl) === []
    assert Cluster.rem_cluster_node([:one, :two, :three], :three) === [:one, :two]
    assert Cluster.rem_cluster_node([:one, :two, :three], :four) === [:one, :two, :three]
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
