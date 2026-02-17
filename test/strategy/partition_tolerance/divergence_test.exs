defmodule Test.Strategy.PartitionTolerance.DivergenceTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.PartitionTolerance.Divergence
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy

  describe "init/2" do
    test "returns strategy unchanged" do
      strategy = %Divergence{}
      assert PartitionToleranceStrategy.init(strategy, %{}) == strategy
    end
  end

  describe "toggle_lock?/3" do
    test "returns false regardless of node" do
      strategy = %Divergence{}
      refute PartitionToleranceStrategy.toggle_lock?(strategy, %{}, :some_node)
      refute PartitionToleranceStrategy.toggle_lock?(strategy, %{}, node())
      refute PartitionToleranceStrategy.toggle_lock?(strategy, %{}, :fake@host)
    end
  end

  describe "toggle_unlock?/3" do
    test "returns false regardless of node" do
      strategy = %Divergence{}
      refute PartitionToleranceStrategy.toggle_unlock?(strategy, %{}, :some_node)
      refute PartitionToleranceStrategy.toggle_unlock?(strategy, %{}, node())
      refute PartitionToleranceStrategy.toggle_unlock?(strategy, %{}, :fake@host)
    end
  end
end
