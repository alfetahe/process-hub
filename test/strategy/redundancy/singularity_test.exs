defmodule Test.Strategy.Redundancy.SingularityTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Redundancy.Singularity
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy

  describe "init/2" do
    test "returns strategy unchanged" do
      strategy = %Singularity{}
      assert RedundancyStrategy.init(strategy, %{}) == strategy
    end
  end

  describe "replication_factor/1" do
    test "always returns 1" do
      assert RedundancyStrategy.replication_factor(%Singularity{}) == 1
    end
  end

  describe "master_node/4" do
    test "returns first node in list" do
      strategy = %Singularity{}
      hub = %{}

      assert RedundancyStrategy.master_node(strategy, hub, :child1, [:node1, :node2, :node3]) ==
               :node1
    end

    test "returns single node when list has one element" do
      strategy = %Singularity{}
      assert RedundancyStrategy.master_node(strategy, %{}, :child1, [:only_node]) == :only_node
    end

    test "returns nil for empty list" do
      strategy = %Singularity{}
      assert RedundancyStrategy.master_node(strategy, %{}, :child1, []) == nil
    end
  end

  describe "handle_redundancy/4" do
    test "returns :ok" do
      strategy = %Singularity{}
      assert RedundancyStrategy.handle_redundancy(strategy, %{}, %{}, []) == :ok
    end
  end
end
