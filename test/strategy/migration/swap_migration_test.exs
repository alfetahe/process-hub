defmodule Test.Strategy.Migration.SwapMigrationTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Migration.SwapMigration

  describe "group_children_by_node/1" do
    test "groups children by target node" do
      cs1 = %{id: :child1}
      cs2 = %{id: :child2}
      cs3 = %{id: :child3}

      forward_to_list = [
        {cs1, %{}, [:node1@host]},
        {cs2, %{}, [:node1@host]},
        {cs3, %{}, [:node2@host]}
      ]

      result = SwapMigration.group_children_by_node(forward_to_list)

      assert length(result[:node1@host]) == 2
      assert length(result[:node2@host]) == 1
    end

    test "handles child with multiple target nodes" do
      cs1 = %{id: :child1}

      forward_to_list = [
        {cs1, %{meta: true}, [:node1@host, :node2@host]}
      ]

      result = SwapMigration.group_children_by_node(forward_to_list)

      assert length(result[:node1@host]) == 1
      assert length(result[:node2@host]) == 1
    end

    test "returns empty map for empty input" do
      assert SwapMigration.group_children_by_node([]) == %{}
    end

    test "preserves metadata" do
      cs1 = %{id: :child1}
      meta = %{custom: "data"}

      result = SwapMigration.group_children_by_node([{cs1, meta, [:node1@host]}])

      [{stored_cs, stored_meta}] = result[:node1@host]
      assert stored_cs == cs1
      assert stored_meta == meta
    end
  end

  describe "find_new_nodes/2" do
    test "returns nodes in new but not in old" do
      old = [:a@host, :b@host]
      new = [:b@host, :c@host, :d@host]

      result = SwapMigration.find_new_nodes(old, new)
      assert :c@host in result
      assert :d@host in result
      refute :b@host in result
    end

    test "returns empty when no new nodes" do
      old = [:a@host, :b@host]
      new = [:a@host, :b@host]

      assert SwapMigration.find_new_nodes(old, new) == []
    end

    test "returns all when old is empty" do
      assert SwapMigration.find_new_nodes([], [:a@host, :b@host]) == [:a@host, :b@host]
    end
  end

  describe "find_existing_nodes/2" do
    test "returns nodes in both lists" do
      old = [:a@host, :b@host, :c@host]
      new = [:b@host, :c@host, :d@host]

      result = SwapMigration.find_existing_nodes(old, new)
      assert :b@host in result
      assert :c@host in result
      refute :a@host in result
      refute :d@host in result
    end

    test "returns empty when no overlap" do
      assert SwapMigration.find_existing_nodes([:a@host], [:b@host]) == []
    end

    test "returns empty when old is empty" do
      assert SwapMigration.find_existing_nodes([], [:a@host]) == []
    end
  end

  describe "eligible_for_sending?/3" do
    test "returns true when registry_nodes is empty (first-time assignment)" do
      assert SwapMigration.eligible_for_sending?([], [:n1@host], node())
    end

    test "returns true when calculated_nodes has only one node" do
      assert SwapMigration.eligible_for_sending?([:old@host], [:n1@host], :old@host)
    end

    test "returns true when local node is first among existing nodes in calculated list" do
      local = node()
      registry_nodes = [local, :n2@host]
      calculated_nodes = [local, :n3@host]

      assert SwapMigration.eligible_for_sending?(registry_nodes, calculated_nodes, local)
    end

    test "returns false when local node is not first existing node" do
      local = node()
      # :a@host sorts before most node names
      registry_nodes = [:a@host, local]
      calculated_nodes = [:a@host, :new@host]

      refute SwapMigration.eligible_for_sending?(registry_nodes, calculated_nodes, local)
    end

    test "returns true when no overlap and local is first sorted old node" do
      # No existing nodes in calculated list, so first sorted registry node takes responsibility
      local = :aaa@host
      registry_nodes = [local, :zzz@host]
      calculated_nodes = [:completely_new@host, :other_new@host]

      assert SwapMigration.eligible_for_sending?(registry_nodes, calculated_nodes, local)
    end

    test "returns false when no overlap and local is not first sorted old node" do
      local = :zzz@host
      registry_nodes = [:aaa@host, local]
      # Need more than 1 calculated node to avoid the "single node" shortcut
      calculated_nodes = [:completely_new@host, :other_new@host]

      refute SwapMigration.eligible_for_sending?(registry_nodes, calculated_nodes, local)
    end
  end

  describe "collect_states/4" do
    test "returns accumulated states immediately when remaining is empty" do
      result = SwapMigration.collect_states([], 1000, [{:prev, :state}], :coldswap_state)
      assert result == [{:prev, :state}]
    end

    test "collects states from messages" do
      # Send messages that will be picked up
      send(self(), {:process_hub, :coldswap_state, :child1, %{key: "val1"}})
      send(self(), {:process_hub, :coldswap_state, :child2, %{key: "val2"}})

      result = SwapMigration.collect_states([:child1, :child2], 1000, [], :coldswap_state)

      assert length(result) == 2
      cids = Enum.map(result, &elem(&1, 0))
      assert :child1 in cids
      assert :child2 in cids
    end

    test "times out when messages don't arrive" do
      result = SwapMigration.collect_states([:child1], 50, [], :coldswap_state)
      assert result == []
    end

    test "returns partial results on timeout" do
      send(self(), {:process_hub, :hotswap_state, :child1, :state1})

      result = SwapMigration.collect_states([:child1, :child2], 50, [], :hotswap_state)

      assert length(result) == 1
      assert {:child1, :state1} in result
    end
  end
end
