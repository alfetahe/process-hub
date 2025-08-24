defmodule StopResultTest do
  use ExUnit.Case
  alias ProcessHub.StopResult

  describe "format/1" do
    test "formats error result" do
      result = %StopResult{
        status: :error,
        errors: [{"child1", :timeout}],
        stopped: [{"child2", [:node1]}]
      }

      assert StopResult.format(result) ==
               {:error, {[{"child1", :timeout}], [{"child2", [:node1]}]}}
    end

    test "formats ok result" do
      result = %StopResult{
        status: :ok,
        stopped: [{"child1", [:node1]}]
      }

      assert StopResult.format(result) == {:ok, [{"child1", [:node1]}]}
    end

    test "formats error tuple" do
      assert StopResult.format({:error, :timeout}) == {:error, :timeout}
    end
  end

  describe "errors/1" do
    test "extracts errors from struct" do
      result = %StopResult{errors: [{"child1", :timeout}]}
      assert StopResult.errors(result) == [{"child1", :timeout}]
    end

    test "handles error tuple" do
      assert StopResult.errors({:error, :timeout}) == {:error, :timeout}
    end
  end

  describe "status/1" do
    test "extracts status from struct" do
      result = %StopResult{status: :ok}
      assert StopResult.status(result) == :ok
    end

    test "handles error tuple" do
      assert StopResult.status({:error, :timeout}) == {:error, :timeout}
    end
  end

  describe "first/1" do
    test "returns first stopped item" do
      result = %StopResult{stopped: [{"child1", [:node1]}]}
      assert StopResult.first(result) == {"child1", [:node1]}
    end

    test "returns nil when no stopped processes" do
      result = %StopResult{stopped: []}
      assert StopResult.first(result) == nil
    end
  end

  describe "cids/1" do
    test "returns all child IDs" do
      result = %StopResult{
        stopped: [
          {"child1", [:node1]},
          {"child2", [:node2]}
        ]
      }

      assert StopResult.cids(result) == ["child1", "child2"]
    end

    test "returns empty list when no stopped processes" do
      result = %StopResult{stopped: []}
      assert StopResult.cids(result) == []
    end
  end

  describe "nodes/1" do
    test "returns all unique nodes" do
      result = %StopResult{
        stopped: [
          {"child1", [:node1, :node2]},
          {"child2", [:node1]}
        ]
      }

      nodes = StopResult.nodes(result)
      assert length(nodes) == 2
      assert :node1 in nodes
      assert :node2 in nodes
    end

    test "returns empty list when no stopped processes" do
      result = %StopResult{stopped: []}
      assert StopResult.nodes(result) == []
    end
  end
end