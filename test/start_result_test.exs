defmodule StartResultTest do
  use ExUnit.Case
  alias ProcessHub.StartResult

  describe "struct creation" do
    test "creates struct with all fields" do
      result = %StartResult{
        status: :ok,
        started: [{"child1", [{:node1, self()}]}],
        errors: [],
        rollback: false
      }

      assert result.status == :ok
      assert result.started == [{"child1", [{:node1, self()}]}]
      assert result.errors == []
      assert result.rollback == false
    end

    test "creates struct with default values" do
      result = %StartResult{}

      assert result.status == nil
      assert result.started == nil
      assert result.errors == nil
      assert result.rollback == nil
    end

    test "creates struct with multiple started processes" do
      pid1 = self()
      pid2 = spawn(fn -> :ok end)
      
      result = %StartResult{
        status: :ok,
        started: [
          {"child1", [{:node1, pid1}]},
          {"child2", [{:node2, pid2}]},
          {"child3", [{:node1, pid1}, {:node2, pid2}]}
        ],
        errors: [],
        rollback: false
      }

      assert result.status == :ok
      assert length(result.started) == 3
      assert result.errors == []
      assert result.rollback == false
    end

    test "creates struct with multiple errors" do
      result = %StartResult{
        status: :error,
        started: [],
        errors: [
          {"child1", :timeout},
          {"child2", {:error, :badarg}},
          {"child3", "custom error"}
        ],
        rollback: true
      }

      assert result.status == :error
      assert result.started == []
      assert length(result.errors) == 3
      assert result.rollback == true
    end
  end

  describe "format/1" do
    test "formats error result with rollback" do
      result = %StartResult{
        status: :error,
        errors: [{"child1", :timeout}],
        started: [{"child2", [{:node1, self()}]}],
        rollback: true
      }

      assert StartResult.format(result) == {:error, {[{"child1", :timeout}], [{"child2", [{:node1, self()}]}]}, :rollback}
    end

    test "formats error result without rollback" do
      result = %StartResult{
        status: :error,
        errors: [{"child1", :timeout}],
        started: [{"child2", [{:node1, self()}]}],
        rollback: false
      }

      assert StartResult.format(result) == {:error, {[{"child1", :timeout}], [{"child2", [{:node1, self()}]}]}}
    end

    test "formats error result with rollback nil (defaults to no rollback)" do
      result = %StartResult{
        status: :error,
        errors: [{"child1", :timeout}],
        started: [{"child2", [{:node1, self()}]}],
        rollback: nil
      }

      assert StartResult.format(result) == {:error, {[{"child1", :timeout}], [{"child2", [{:node1, self()}]}]}}
    end

    test "formats ok result" do
      result = %StartResult{
        status: :ok,
        started: [{"child1", [{:node1, self()}]}]
      }

      assert StartResult.format(result) == {:ok, [{"child1", [{:node1, self()}]}]}
    end

    test "formats ok result with empty started list" do
      result = %StartResult{
        status: :ok,
        started: []
      }

      assert StartResult.format(result) == {:ok, []}
    end

    test "formats ok result with multiple started processes" do
      pid1 = self()
      pid2 = spawn(fn -> :ok end)
      
      result = %StartResult{
        status: :ok,
        started: [
          {"child1", [{:node1, pid1}]},
          {"child2", [{:node2, pid2}]},
          {"child3", [{:node1, pid1}, {:node2, pid2}]}
        ]
      }

      expected = [
        {"child1", [{:node1, pid1}]},
        {"child2", [{:node2, pid2}]},
        {"child3", [{:node1, pid1}, {:node2, pid2}]}
      ]
      assert StartResult.format(result) == {:ok, expected}
    end

    test "formats error tuple" do
      assert StartResult.format({:error, :timeout}) == {:error, :timeout}
    end

    test "formats error tuple with complex reason" do
      reason = {:shutdown, {:error, :econnrefused}}
      assert StartResult.format({:error, reason}) == {:error, reason}
    end

    test "formats error result with multiple errors and multiple started" do
      pid1 = self()
      pid2 = spawn(fn -> :ok end)
      pid3 = spawn(fn -> :ok end)
      
      result = %StartResult{
        status: :error,
        errors: [
          {"child1", :timeout}, 
          {"child2", {:error, :badarg}},
          {"child3", {:shutdown, :normal}},
          {"child4", "custom error"}
        ],
        started: [
          {"child5", [{:node1, pid1}]},
          {"child6", [{:node2, pid2}]},
          {"child7", [{:node1, pid3}, {:node3, pid1}]}
        ]
      }

      expected_errors = [
        {"child1", :timeout}, 
        {"child2", {:error, :badarg}},
        {"child3", {:shutdown, :normal}},
        {"child4", "custom error"}
      ]
      expected_started = [
        {"child5", [{:node1, pid1}]},
        {"child6", [{:node2, pid2}]},
        {"child7", [{:node1, pid3}, {:node3, pid1}]}
      ]
      assert StartResult.format(result) == {:error, {expected_errors, expected_started}}
    end

    test "formats error result with multiple started processes" do
      pid1 = self()
      pid2 = spawn(fn -> :ok end)
      
      result = %StartResult{
        status: :error,
        errors: [{"child1", :timeout}],
        started: [
          {"child2", [{:node1, pid1}]},
          {"child3", [{:node2, pid2}]}
        ]
      }

      expected_errors = [{"child1", :timeout}]
      expected_started = [
        {"child2", [{:node1, pid1}]},
        {"child3", [{:node2, pid2}]}
      ]
      assert StartResult.format(result) == {:error, {expected_errors, expected_started}}
    end

    test "formats error result with processes started on multiple nodes" do
      pid1 = self()
      
      result = %StartResult{
        status: :error,
        errors: [{"child1", :timeout}],
        started: [{"child2", [{:node1, pid1}, {:node2, pid1}]}]
      }

      expected_errors = [{"child1", :timeout}]
      expected_started = [{"child2", [{:node1, pid1}, {:node2, pid1}]}]
      assert StartResult.format(result) == {:error, {expected_errors, expected_started}}
    end
  end

  describe "errors/1" do
    test "extracts errors from StartResult struct" do
      result = %StartResult{
        errors: [{"child1", :timeout}, {"child2", {:error, :badarg}}]
      }

      assert StartResult.errors(result) == [{"child1", :timeout}, {"child2", {:error, :badarg}}]
    end

    test "extracts empty errors list" do
      result = %StartResult{errors: []}
      assert StartResult.errors(result) == []
    end

    test "extracts multiple errors with different types" do
      result = %StartResult{
        errors: [
          {"child1", :timeout}, 
          {"child2", {:error, :badarg}},
          {:child3, {:shutdown, :normal}},
          {"child4", "string error"},
          {"child5", 42}
        ]
      }

      expected = [
        {"child1", :timeout}, 
        {"child2", {:error, :badarg}},
        {:child3, {:shutdown, :normal}},
        {"child4", "string error"},
        {"child5", 42}
      ]
      assert StartResult.errors(result) == expected
    end

    test "handles error tuple" do
      assert StartResult.errors({:error, :timeout}) == {:error, :timeout}
    end

    test "handles error tuple with complex reason" do
      reason = {:shutdown, {:error, :econnrefused}}
      assert StartResult.errors({:error, reason}) == {:error, reason}
    end
  end

  describe "status/1" do
    test "extracts ok status from StartResult struct" do
      result = %StartResult{status: :ok}
      assert StartResult.status(result) == :ok
    end

    test "extracts error status from StartResult struct" do
      result = %StartResult{status: :error}
      assert StartResult.status(result) == :error
    end

    test "extracts nil status" do
      result = %StartResult{status: nil}
      assert StartResult.status(result) == nil
    end

    test "handles error tuple" do
      assert StartResult.status({:error, :timeout}) == {:error, :timeout}
    end

    test "handles error tuple with complex reason" do
      reason = {:shutdown, {:error, :econnrefused}}
      assert StartResult.status({:error, reason}) == {:error, reason}
    end
  end

  describe "edge cases and type conformance" do
    test "handles empty struct" do
      result = %StartResult{}
      
      assert StartResult.errors(result) == nil
      assert StartResult.status(result) == nil
    end

    test "handles struct with atom child_ids" do
      result = %StartResult{
        status: :ok,
        started: [{:child_atom, [{:node1, self()}]}]
      }

      assert StartResult.format(result) == {:ok, [{:child_atom, [{:node1, self()}]}]}
    end

    test "handles struct with string child_ids" do
      result = %StartResult{
        status: :error,
        errors: [{"child_string", :timeout}],
        started: []
      }

      assert StartResult.format(result) == {:error, {[{"child_string", :timeout}], []}}
    end

    test "handles struct with mixed error types" do
      result = %StartResult{
        status: :error,
        errors: [
          {"child1", :timeout},
          {"child2", {:error, :badarg}},
          {"child3", "string error"},
          {"child4", 42}
        ],
        started: []
      }

      expected_errors = [
        {"child1", :timeout},
        {"child2", {:error, :badarg}},
        {"child3", "string error"},
        {"child4", 42}
      ]
      assert StartResult.format(result) == {:error, {expected_errors, []}}
    end
  end
end
