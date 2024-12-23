defmodule Test.Service.RingTest do
  alias ProcessHub.Service.Ring
  alias :hash_ring, as: HashRing

  use ExUnit.Case

  setup do
    Test.Helper.SetupHelper.setup_base(%{}, :ring_test)
  end

  test "create ring" do
    hub_nodes = [:node1, :node2, :node3]
    hash_ring = Ring.create_ring(hub_nodes)

    assert HashRing.get_node_count(hash_ring) === length(hub_nodes)
  end

  test "get ring", %{hub_id: hub_id} = _context do
    {key, type, _} = Ring.get_ring(hub_id)

    assert key === :hash_ring
    assert type === :hash_ring_static
  end

  test "add node", %{hub_id: hub_id} = _context do
    hash_ring = Ring.get_ring(hub_id)
    assert HashRing.get_node_count(hash_ring) === 1
    hash_ring = Ring.add_node(hash_ring, :node)
    assert HashRing.get_node_count(hash_ring) === 2

    assert HashRing.get_nodes(hash_ring) === %{
             "process_hub@127.0.0.1":
               {:hash_ring_node, :"process_hub@127.0.0.1", :"process_hub@127.0.0.1", 1},
             node: {:hash_ring_node, :node, :node, 1}
           }
  end

  test "remove node", %{hub_id: hub_id} = _context do
    hash_ring = Ring.get_ring(hub_id)
    hash_ring = Ring.add_node(hash_ring, :node)
    assert HashRing.get_node_count(hash_ring) === 2
    hash_ring = Ring.remove_node(hash_ring, :node)
    assert HashRing.get_node_count(hash_ring) === 1

    assert HashRing.get_nodes(hash_ring) === %{
             "process_hub@127.0.0.1": {:hash_ring_node, :"process_hub@127.0.0.1", :"process_hub@127.0.0.1", 1}
           }
  end

  test "key to nodes", %{hub_id: hub_id} = _context do
    hash_ring = Ring.get_ring(hub_id)

    assert Ring.key_to_nodes(hash_ring, "key1", 1) === [:"process_hub@127.0.0.1"]
    assert Ring.key_to_nodes(hash_ring, "key2", 1) === [:"process_hub@127.0.0.1"]

    hash_ring =
      Ring.add_node(hash_ring, :node1)
      |> Ring.add_node(:node2)
      |> Ring.add_node(:node3)

    nodes =
      :hash_ring.collect_nodes(5000, 4, hash_ring)
      |> Enum.map(fn {_, node, _, _} -> node end)

    assert length(nodes) === 4

    Enum.each(nodes, fn node ->
      Enum.member?([:node1, :node2, :node3, :"process_hub@127.0.0.1"], node)
    end)

    assert Ring.key_to_nodes(hash_ring, 5000, 1) === Enum.take(nodes, 1)
    assert Ring.key_to_nodes(hash_ring, 5000, 2) === Enum.take(nodes, 2)
    assert Ring.key_to_nodes(hash_ring, 5000, 3) === Enum.take(nodes, 3)
    assert Ring.key_to_nodes(hash_ring, 5000, 4) === Enum.take(nodes, 4)
  end

  test "key to node", %{hub_id: hub_id} = _context do
    hash_ring = Ring.get_ring(hub_id)

    assert Ring.key_to_node(hash_ring, "key1", 1) === :"process_hub@127.0.0.1"
    assert Ring.key_to_node(hash_ring, "key2", 1) === :"process_hub@127.0.0.1"

    hash_ring =
      Ring.add_node(hash_ring, :node1)
      |> Ring.add_node(:node2)
      |> Ring.add_node(:node3)

    nodes =
      :hash_ring.collect_nodes(5000, 3, hash_ring)
      |> Enum.map(fn {_, node, _, _} -> node end)

    first_node = Enum.at(nodes, 0)

    assert Ring.key_to_node(hash_ring, 5000, 1) === first_node
    assert Ring.key_to_node(hash_ring, 5000, 2) === first_node
    assert Ring.key_to_node(hash_ring, 5000, 3) === first_node
  end

  test "nodes", %{hub_id: hub_id} = _context do
    hash_ring = Ring.get_ring(hub_id)

    assert Ring.nodes(hash_ring) === [:"process_hub@127.0.0.1"]
  end
end
