defmodule Test.Request.Handler.StopChildrenRequestTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Request.Handler.StopChildrenRequest
  alias ProcessHub.Service.RequestManager

  # Helper: create a minimal operation for new/3
  defp make_operation(opts \\ []) do
    %RequestManager{
      transaction_id: Keyword.get(opts, :transaction_id, make_ref()),
      hub_id: Keyword.get(opts, :hub_id, :test_hub),
      handler: StopChildrenRequest,
      nodes_data: [{node(), []}],
      completed_nodes: MapSet.new(),
      expires_at: System.monotonic_time(:millisecond) + 60_000,
      sub_requests: [],
      options: Keyword.get(opts, :options, [])
    }
  end

  describe "new/3" do
    test "creates correct struct from operation" do
      op = make_operation(options: [reply_to: [self()]])

      req = StopChildrenRequest.new(op, :target_node, [%{child_id: :c1}])

      assert req.transaction_id == op.transaction_id
      assert req.hub_id == :test_hub
      assert req.originating_node == node()
      assert req.reply_to == [self()]
      assert req.node == :target_node
      assert req.children == [%{child_id: :c1}]
      assert req.status == :dispatched
    end

    test "strips routing opts from passthrough options" do
      op = make_operation(options: [reply_to: [self()], custom_opt: true])

      req = StopChildrenRequest.new(op, :target, [])

      assert Keyword.get(req.options, :custom_opt) == true
      refute Keyword.has_key?(req.options, :reply_to)
    end
  end

  describe "response_type/0" do
    test "returns :operation_response" do
      assert StopChildrenRequest.response_type() == :operation_response
    end
  end

  describe "to_stop_opts/1" do
    test "converts to keyword options" do
      req = %StopChildrenRequest{
        transaction_id: :txn,
        hub_id: :hub,
        originating_node: node(),
        reply_to: nil,
        node: node(),
        children: [],
        options: []
      }

      opts = StopChildrenRequest.to_stop_opts(req)
      assert is_list(opts)
      assert Keyword.get(opts, :hub_id) == :hub
    end
  end

  describe "build_node_response/1" do
    test "with map format (child_id key)" do
      children = [
        %{child_id: :child1},
        %{child_id: :child2}
      ]

      result = StopChildrenRequest.build_node_response(children)

      assert length(result) == 2
      assert {:child1, :ok} in result
      assert {:child2, :ok} in result
    end

    test "with tuple format filters to local node" do
      local = node()

      results = [
        {:child1, :ok, local},
        {:child2, :ok, :remote@host}
      ]

      result = StopChildrenRequest.build_node_response(results)

      assert length(result) == 1
      assert {:child1, :ok} in result
    end

    test "with tuple format preserves result" do
      local = node()

      results = [
        {:child1, {:error, :not_found}, local}
      ]

      result = StopChildrenRequest.build_node_response(results)

      assert [{:child1, {:error, :not_found}}] = result
    end
  end

  describe "aggregate_results/1" do
    test "aggregates successful results" do
      sub_req = %StopChildrenRequest{
        node: :node1,
        results: [{:child1, :ok}],
        children: []
      }

      op = %RequestManager{sub_requests: [sub_req], options: []}
      result = StopChildrenRequest.aggregate_results(op)

      assert %ProcessHub.StopResult{} = result
      assert result.status == :ok
      assert length(result.stopped) == 1
      assert result.errors == []
    end

    test "handles nil results (no response)" do
      sub_req = %StopChildrenRequest{
        node: :node1,
        results: nil,
        children: [%{child_id: :child1}]
      }

      op = %RequestManager{sub_requests: [sub_req], options: []}
      result = StopChildrenRequest.aggregate_results(op)

      assert result.status == :error
      assert length(result.errors) == 1
      assert {:child1, {:error, :no_response}} in result.errors
    end

    test "includes not_found_children from options" do
      sub_req = %StopChildrenRequest{
        node: :node1,
        results: [{:child1, :ok}],
        children: []
      }

      op = %RequestManager{
        sub_requests: [sub_req],
        options: [not_found_children: [:child_missing]]
      }

      result = StopChildrenRequest.aggregate_results(op)

      assert result.status == :error
      assert {:child_missing, {:error, :not_found}} in result.errors
      assert length(result.stopped) == 1
    end

    test "handles error results from node" do
      sub_req = %StopChildrenRequest{
        node: :node1,
        results: [{:child1, {:error, :timeout}}],
        children: []
      }

      op = %RequestManager{sub_requests: [sub_req], options: []}
      result = StopChildrenRequest.aggregate_results(op)

      assert result.status == :error
      # The error reason is extracted from the {:error, reason} tuple
      assert {:child1, :timeout} in result.errors
    end

    test "aggregates from multiple sub_requests" do
      sub1 = %StopChildrenRequest{
        node: :node1,
        results: [{:child1, :ok}],
        children: []
      }

      sub2 = %StopChildrenRequest{
        node: :node2,
        results: [{:child2, :ok}],
        children: []
      }

      op = %RequestManager{sub_requests: [sub1, sub2], options: []}
      result = StopChildrenRequest.aggregate_results(op)

      assert result.status == :ok
      assert length(result.stopped) == 2
    end
  end

  describe "post_process/3" do
    test "returns result unchanged" do
      op = %RequestManager{options: []}

      stop_result = %ProcessHub.StopResult{
        status: :ok,
        stopped: [{:child1, [:node1]}],
        errors: []
      }

      assert StopChildrenRequest.post_process(op, stop_result, %{}) == stop_result
    end
  end
end
