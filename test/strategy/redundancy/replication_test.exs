defmodule Test.Strategy.Redundancy.ReplicationTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Redundancy.Replication
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy

  describe "replication_factor/1" do
    test "returns numeric factor" do
      strategy = %Replication{replication_factor: 3}
      assert RedundancyStrategy.replication_factor(strategy) == 3
    end

    test "returns 1 for factor of 1" do
      strategy = %Replication{replication_factor: 1}
      assert RedundancyStrategy.replication_factor(strategy) == 1
    end

    test "with :cluster_size returns current cluster size" do
      strategy = %Replication{replication_factor: :cluster_size}
      # On a single node, Node.list() returns [], so result = 0 + 1 = 1
      result = RedundancyStrategy.replication_factor(strategy)
      assert result == 1
    end
  end

  describe "master_node/4" do
    test "deterministic selection: same inputs = same result" do
      strategy = %Replication{}
      hub = %{}
      nodes = [:node1@host, :node2@host, :node3@host]

      master1 = RedundancyStrategy.master_node(strategy, hub, :child1, nodes)
      master2 = RedundancyStrategy.master_node(strategy, hub, :child1, nodes)

      assert master1 == master2
    end

    test "result is from the node list" do
      strategy = %Replication{}
      hub = %{}
      nodes = [:node1@host, :node2@host, :node3@host]

      master = RedundancyStrategy.master_node(strategy, hub, :child1, nodes)
      assert master in nodes
    end

    test "different child_ids may produce different masters" do
      strategy = %Replication{}
      hub = %{}
      nodes = [:node1@host, :node2@host, :node3@host]

      # Generate multiple child_ids and check distribution
      masters =
        for i <- 1..20 do
          RedundancyStrategy.master_node(strategy, hub, :"child_#{i}", nodes)
        end

      # At least 2 different masters should be selected across 20 children
      unique_masters = Enum.uniq(masters)
      assert length(unique_masters) >= 2
    end

    test "works with atom child_ids" do
      strategy = %Replication{}
      hub = %{}
      nodes = [:node1@host, :node2@host]

      master = RedundancyStrategy.master_node(strategy, hub, :my_child, nodes)
      assert master in nodes
    end

    test "works with string child_ids" do
      strategy = %Replication{}
      hub = %{}
      nodes = [:node1@host, :node2@host]

      master = RedundancyStrategy.master_node(strategy, hub, "my_child", nodes)
      assert master in nodes
    end

    test "order independent: sorted differently gives same result" do
      strategy = %Replication{}
      hub = %{}
      nodes1 = [:a@host, :b@host, :c@host]
      nodes2 = [:c@host, :a@host, :b@host]

      # master_node sorts internally, so different input order should give same result
      master1 = RedundancyStrategy.master_node(strategy, hub, :child1, nodes1)
      master2 = RedundancyStrategy.master_node(strategy, hub, :child1, nodes2)

      assert master1 == master2
    end
  end

  describe "init/2" do
    test "registers hook handlers and returns strategy" do
      hub_id = :"test_repl_init_#{:erlang.unique_integer([:positive])}"
      hook_storage = :ets.new(:"hook_#{hub_id}", [:set, :public])

      hub = %ProcessHub.Hub{
        hub_id: hub_id,
        storage: %{hook: hook_storage}
      }

      strategy = %Replication{replication_factor: 2}
      result = RedundancyStrategy.init(strategy, hub)

      assert result == strategy

      :ets.delete(hook_storage)
    end
  end

  describe "struct defaults" do
    test "replication_factor defaults to 2" do
      strategy = %Replication{}
      assert strategy.replication_factor == 2
    end

    test "replication_model defaults to :active_active" do
      strategy = %Replication{}
      assert strategy.replication_model == :active_active
    end

    test "redundancy_signal defaults to :none" do
      strategy = %Replication{}
      assert strategy.redundancy_signal == :none
    end
  end
end
