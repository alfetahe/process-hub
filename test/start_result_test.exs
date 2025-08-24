defmodule StartResultTest do
  use ExUnit.Case
  alias ProcessHub.StartResult

  describe "format/1" do
    test "formats error result with rollback" do
      result = %StartResult{
        status: :error,
        errors: [{"child1", :timeout}],
        started: [{"child2", [{:node1, self()}]}],
        rollback: true
      }

      assert StartResult.format(result) ==
               {:error, {[{"child1", :timeout}], [{"child2", [{:node1, self()}]}]}, :rollback}
    end

    test "formats error result without rollback" do
      result = %StartResult{
        status: :error,
        errors: [{"child1", :timeout}],
        started: [{"child2", [{:node1, self()}]}]
      }

      assert StartResult.format(result) ==
               {:error, {[{"child1", :timeout}], [{"child2", [{:node1, self()}]}]}}
    end

    test "formats ok result" do
      result = %StartResult{
        status: :ok,
        started: [{"child1", [{:node1, self()}]}]
      }

      assert StartResult.format(result) == {:ok, [{"child1", [{:node1, self()}]}]}
    end

    test "formats error tuple" do
      assert StartResult.format({:error, :timeout}) == {:error, :timeout}
    end
  end

  describe "errors/1" do
    test "extracts errors from struct" do
      result = %StartResult{errors: [{"child1", :timeout}]}
      assert StartResult.errors(result) == [{"child1", :timeout}]
    end

    test "handles error tuple" do
      assert StartResult.errors({:error, :timeout}) == {:error, :timeout}
    end
  end

  describe "status/1" do
    test "extracts status from struct" do
      result = %StartResult{status: :ok}
      assert StartResult.status(result) == :ok
    end

    test "handles error tuple" do
      assert StartResult.status({:error, :timeout}) == {:error, :timeout}
    end
  end

  describe "pid/1" do
    test "returns first result's first pid" do
      pid = self()
      result = %StartResult{started: [{"child1", [{:node1, pid}]}]}
      assert StartResult.pid(result) == pid
    end

    test "returns nil when no started processes" do
      result = %StartResult{started: []}
      assert StartResult.pid(result) == nil
    end
  end

  describe "pids/1" do
    test "returns all pids from started processes" do
      pid1 = self()
      pid2 = spawn(fn -> :ok end)
      
      result = %StartResult{
        started: [
          {"child1", [{:node1, pid1}, {:node2, pid2}]},
          {"child2", [{:node3, pid1}]}
        ]
      }

      pids = StartResult.pids(result)
      assert length(pids) == 3
      assert pid1 in pids
      assert pid2 in pids
    end

    test "returns empty list when no started processes" do
      result = %StartResult{started: []}
      assert StartResult.pids(result) == []
    end
  end

  describe "node/1" do
    test "returns first result's first node" do
      pid = self()
      result = %StartResult{started: [{"child1", [{:node1, pid}]}]}
      assert StartResult.node(result) == :node1
    end

    test "returns nil when no started processes" do
      result = %StartResult{started: []}
      assert StartResult.node(result) == nil
    end
  end

  describe "nodes/1" do
    test "returns all unique nodes" do
      pid = self()
      
      result = %StartResult{
        started: [
          {"child1", [{:node1, pid}, {:node2, pid}]},
          {"child2", [{:node1, pid}]}
        ]
      }

      nodes = StartResult.nodes(result)
      assert length(nodes) == 2
      assert :node1 in nodes
      assert :node2 in nodes
    end

    test "returns empty list when no started processes" do
      result = %StartResult{started: []}
      assert StartResult.nodes(result) == []
    end
  end

  describe "first/1" do
    test "returns first started item" do
      pid = self()
      result = %StartResult{started: [{"child1", [{:node1, pid}]}]}
      assert StartResult.first(result) == {"child1", [{:node1, pid}]}
    end

    test "returns nil when no started processes" do
      result = %StartResult{started: []}
      assert StartResult.first(result) == nil
    end
  end

  describe "cids/1" do
    test "returns all child IDs" do
      pid = self()
      
      result = %StartResult{
        started: [
          {"child1", [{:node1, pid}]},
          {"child2", [{:node2, pid}]}
        ]
      }

      assert StartResult.cids(result) == ["child1", "child2"]
    end

    test "returns empty list when no started processes" do
      result = %StartResult{started: []}
      assert StartResult.cids(result) == []
    end
  end
end