defmodule Test.Request.Handler.StartChildrenRequestTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Request.Handler.StartChildrenRequest
  alias ProcessHub.Request.Handler.StartChildrenRequest.PostStartData
  alias ProcessHub.Service.RequestManager

  defp make_operation(opts) do
    %RequestManager{
      transaction_id: Keyword.get(opts, :transaction_id, make_ref()),
      hub_id: Keyword.get(opts, :hub_id, :test_hub),
      handler: StartChildrenRequest,
      nodes_data: [{node(), []}],
      completed_nodes: MapSet.new(),
      expires_at: System.monotonic_time(:millisecond) + 60_000,
      sub_requests: [],
      options: Keyword.get(opts, :options, [])
    }
  end

  describe "new/3" do
    test "creates correct struct from operation" do
      op = make_operation(options: [request_signature: 42, reply_to: [self()]])

      req = StartChildrenRequest.new(op, :target_node, [%{child_id: :c1}])

      assert req.transaction_id == op.transaction_id
      assert req.hub_id == :test_hub
      assert req.originating_node == node()
      assert req.reply_to == [self()]
      assert req.node == :target_node
      assert req.children == [%{child_id: :c1}]
      assert req.request_signature == 42
      assert req.status == :dispatched
      # Routing opts stripped from passthrough options
      refute Keyword.has_key?(req.options, :reply_to)
    end
  end

  describe "response_type/0" do
    test "returns :operation_response" do
      assert StartChildrenRequest.response_type() == :operation_response
    end
  end

  describe "store_format/1" do
    test "converts PostStartData list to registry map" do
      pid = self()

      post_data = [
        %PostStartData{
          cid: :child1,
          pid: pid,
          child_spec: %{id: :child1},
          result: {:ok, pid},
          child_nodes: [{node(), pid}],
          nodes: [node()],
          has_errors: false,
          metadata: %{key: "val"}
        }
      ]

      result = StartChildrenRequest.store_format(post_data)

      assert is_map(result)
      {cs, cn, m} = result[:child1]
      assert cs == %{id: :child1}
      assert cn == [{node(), pid}]
      assert m == %{key: "val"}
    end

    test "filters out entries with errors" do
      post_data = [
        %PostStartData{
          cid: :child_ok,
          child_spec: %{id: :child_ok},
          child_nodes: [],
          metadata: %{},
          has_errors: false
        },
        %PostStartData{
          cid: :child_err,
          child_spec: %{id: :child_err},
          child_nodes: [],
          metadata: %{},
          has_errors: true
        }
      ]

      result = StartChildrenRequest.store_format(post_data)

      assert Map.has_key?(result, :child_ok)
      refute Map.has_key?(result, :child_err)
    end
  end

  describe "build_node_response/1" do
    test "builds response tuples for local node only" do
      pid = self()
      local = node()

      post_data = [
        %PostStartData{cid: :local_child, result: {:ok, pid}, for_node: local},
        %PostStartData{cid: :remote_child, result: {:ok, pid}, for_node: :remote@host}
      ]

      result = StartChildrenRequest.build_node_response(post_data)

      assert length(result) == 1
      assert {:local_child, {:ok, ^pid}} = hd(result)
    end
  end

  describe "aggregate_results/1" do
    test "aggregates successful results" do
      pid = self()

      sub_req = %StartChildrenRequest{
        node: :node1,
        results: [{:child1, {:ok, pid}}],
        children: []
      }

      op = %RequestManager{sub_requests: [sub_req], options: []}
      result = StartChildrenRequest.aggregate_results(op)

      assert %ProcessHub.StartResult{} = result
      assert result.status == :ok
      assert length(result.started) == 1
      assert result.errors == []
      assert result.rollback == false
    end

    test "handles nil results as no_response errors" do
      sub_req = %StartChildrenRequest{
        node: :node1,
        results: nil,
        children: [%{child_id: :child1}]
      }

      op = %RequestManager{sub_requests: [sub_req], options: []}
      result = StartChildrenRequest.aggregate_results(op)

      assert result.status == :error
      assert [{:child1, {:error, :no_response}}] = result.errors
    end

    test "aggregates mixed success and error" do
      pid = self()

      sub_req = %StartChildrenRequest{
        node: :node1,
        results: [{:child1, {:ok, pid}}, {:child2, {:error, :crash}}],
        children: []
      }

      op = %RequestManager{sub_requests: [sub_req], options: []}
      result = StartChildrenRequest.aggregate_results(op)

      assert result.status == :error
      assert length(result.started) == 1
      assert length(result.errors) == 1
    end
  end

  describe "post_process/3" do
    test "returns result unchanged for :continue and default on_failure" do
      start_result = %ProcessHub.StartResult{
        status: :error,
        started: [],
        errors: [{:child1, :crash}],
        rollback: false
      }

      # Explicit :continue
      op_continue = %RequestManager{options: [on_failure: :continue]}
      assert StartChildrenRequest.post_process(op_continue, start_result, %{}) == start_result

      # Default (no on_failure option)
      op_default = %RequestManager{options: []}
      assert StartChildrenRequest.post_process(op_default, start_result, %{}) == start_result
    end
  end
end
