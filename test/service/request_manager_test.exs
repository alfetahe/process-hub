defmodule Test.Service.RequestManagerTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Service.RequestManager
  alias ProcessHub.Request.Handler.StartChildrenRequest
  alias ProcessHub.Request.Handler.StopChildrenRequest
  alias ProcessHub.Request.Handler.PidsRegisterRequest
  alias ProcessHub.Request.Handler.PidsUnregisterRequest
  alias ProcessHub.Hub

  # Helper to create a minimal hub state with pending_operations
  defp hub_state(pending \\ %{}) do
    %Hub{
      hub_id: :test_hub,
      pending_operations: pending
    }
  end

  # Helper to create a minimal operation
  defp make_operation(opts \\ []) do
    transaction_id = Keyword.get(opts, :transaction_id, make_ref())
    hub_id = Keyword.get(opts, :hub_id, :test_hub)
    nodes_data = Keyword.get(opts, :nodes_data, [{node(), []}])
    timeout = Keyword.get(opts, :timeout, 60_000)

    %RequestManager{
      transaction_id: transaction_id,
      hub_id: hub_id,
      handler: StartChildrenRequest,
      nodes_data: nodes_data,
      completed_nodes: MapSet.new(),
      expires_at: System.monotonic_time(:millisecond) + timeout,
      sub_requests: [],
      options: []
    }
  end

  ##############################################################################
  # State management tests
  ##############################################################################

  describe "store/2" do
    test "adds operation to pending_operations" do
      state = hub_state()
      op = make_operation()

      new_state = RequestManager.store(state, op)
      assert Map.has_key?(new_state.pending_operations, op.transaction_id)
      assert new_state.pending_operations[op.transaction_id] == op
    end

    test "preserves existing operations" do
      op1 = make_operation()
      state = hub_state(%{op1.transaction_id => op1})

      op2 = make_operation()
      new_state = RequestManager.store(state, op2)

      assert map_size(new_state.pending_operations) == 2
    end
  end

  describe "get/2" do
    test "retrieves operation by transaction_id" do
      op = make_operation()
      state = hub_state(%{op.transaction_id => op})

      assert RequestManager.get(state, op.transaction_id) == op
    end

    test "returns nil for missing transaction_id" do
      state = hub_state()
      assert RequestManager.get(state, make_ref()) == nil
    end
  end

  describe "update/2" do
    test "updates existing operation" do
      op = make_operation()
      state = hub_state(%{op.transaction_id => op})

      updated_op = %{op | hub_id: :updated_hub}
      new_state = RequestManager.update(state, updated_op)

      assert new_state.pending_operations[op.transaction_id].hub_id == :updated_hub
    end
  end

  describe "remove/2" do
    test "removes operation from pending_operations" do
      op = make_operation()
      state = hub_state(%{op.transaction_id => op})

      new_state = RequestManager.remove(state, op.transaction_id)
      assert new_state.pending_operations == %{}
    end

    test "does not crash when removing nonexistent key" do
      state = hub_state()
      new_state = RequestManager.remove(state, make_ref())
      assert new_state.pending_operations == %{}
    end
  end

  describe "cleanup_expired/1" do
    test "removes expired operations" do
      expired_op = make_operation(timeout: -1000)
      state = hub_state(%{expired_op.transaction_id => expired_op})

      new_state = RequestManager.cleanup_expired(state)
      assert new_state.pending_operations == %{}
    end

    test "keeps valid operations" do
      valid_op = make_operation(timeout: 60_000)
      state = hub_state(%{valid_op.transaction_id => valid_op})

      new_state = RequestManager.cleanup_expired(state)
      assert map_size(new_state.pending_operations) == 1
    end

    test "removes only expired, keeps valid" do
      expired_op = make_operation(timeout: -1000)
      valid_op = make_operation(timeout: 60_000)

      state =
        hub_state(%{
          expired_op.transaction_id => expired_op,
          valid_op.transaction_id => valid_op
        })

      new_state = RequestManager.cleanup_expired(state)
      assert map_size(new_state.pending_operations) == 1
      assert Map.has_key?(new_state.pending_operations, valid_op.transaction_id)
    end
  end

  ##############################################################################
  # Tracking utilities
  ##############################################################################

  describe "expired?/1" do
    test "returns false for future timestamp" do
      op = make_operation(timeout: 60_000)
      refute RequestManager.expired?(op)
    end

    test "returns true for past timestamp" do
      op = make_operation(timeout: -1000)
      assert RequestManager.expired?(op)
    end
  end

  describe "all_responded?/1" do
    test "returns true when completed_nodes matches expected" do
      op = %{
        nodes_data: [{:node1, []}, {:node2, []}],
        completed_nodes: MapSet.new([:node1, :node2])
      }

      assert RequestManager.all_responded?(op)
    end

    test "returns false when some nodes pending" do
      op = %{
        nodes_data: [{:node1, []}, {:node2, []}],
        completed_nodes: MapSet.new([:node1])
      }

      refute RequestManager.all_responded?(op)
    end

    test "returns true for empty nodes_data with empty completed" do
      op = %{nodes_data: [], completed_nodes: MapSet.new()}
      assert RequestManager.all_responded?(op)
    end
  end

  describe "set_awaiter/2" do
    test "sets the awaiter field" do
      op = make_operation()
      from = {self(), make_ref()}

      updated = RequestManager.set_awaiter(op, from)
      assert updated.awaiter == from
    end
  end

  describe "record_response/4" do
    test "updates correct sub_request and marks node completed" do
      sub_req = %StartChildrenRequest{
        node: :node1,
        results: nil,
        status: :dispatched,
        children: []
      }

      op = %{
        sub_requests: [sub_req],
        completed_nodes: MapSet.new()
      }

      results = [{:child1, {:ok, self()}}]
      updated = RequestManager.record_response(op, :node1, results, :results)

      assert MapSet.member?(updated.completed_nodes, :node1)
      [updated_sub] = updated.sub_requests
      assert updated_sub.results == results
      assert updated_sub.status == :completed
    end

    test "does not modify sub_requests for other nodes" do
      sub1 = %StartChildrenRequest{node: :node1, results: nil, status: :dispatched, children: []}
      sub2 = %StartChildrenRequest{node: :node2, results: nil, status: :dispatched, children: []}

      op = %{
        sub_requests: [sub1, sub2],
        completed_nodes: MapSet.new()
      }

      updated = RequestManager.record_response(op, :node1, [:result], :results)

      [u1, u2] = updated.sub_requests
      assert u1.results == [:result]
      assert u2.results == nil
    end
  end

  ##############################################################################
  # process_response
  ##############################################################################

  describe "process_response/3" do
    test "returns {:complete, op} when all nodes responded" do
      sub_req = %StartChildrenRequest{
        node: node(),
        results: nil,
        status: :dispatched,
        children: []
      }

      op = make_operation(nodes_data: [{node(), []}])
      op = %{op | sub_requests: [sub_req]}

      {:complete, updated} =
        RequestManager.process_response(op, node(), [{:child1, {:ok, self()}}])

      assert MapSet.member?(updated.completed_nodes, node())
    end

    test "returns {:pending, op} when some nodes still pending" do
      sub1 = %StartChildrenRequest{node: :node1, results: nil, status: :dispatched, children: []}
      sub2 = %StartChildrenRequest{node: :node2, results: nil, status: :dispatched, children: []}

      op = make_operation(nodes_data: [{:node1, []}, {:node2, []}])
      op = %{op | sub_requests: [sub1, sub2]}

      {:pending, updated} =
        RequestManager.process_response(op, :node1, [{:child1, {:ok, self()}}])

      assert MapSet.member?(updated.completed_nodes, :node1)
      refute MapSet.member?(updated.completed_nodes, :node2)
    end
  end

  ##############################################################################
  # Request splitting
  ##############################################################################

  describe "split/1 with StartChildrenRequest" do
    test "returns single request when children <= 1000" do
      children = for i <- 1..100, do: %{child_id: :"child_#{i}"}

      req = %StartChildrenRequest{children: children}
      assert [^req] = RequestManager.split(req)
    end

    test "splits into chunks when children > 1000" do
      children = for i <- 1..2500, do: %{child_id: :"child_#{i}"}
      req = %StartChildrenRequest{children: children}

      result = RequestManager.split(req)
      assert length(result) == 3

      total_children = Enum.flat_map(result, & &1.children) |> length()
      assert total_children == 2500
    end
  end

  describe "split/1 with StopChildrenRequest" do
    test "returns single request when children <= 1000" do
      children = for i <- 1..100, do: %{child_id: :"child_#{i}"}
      req = %StopChildrenRequest{children: children}

      assert [^req] = RequestManager.split(req)
    end

    test "splits into chunks when children > 1000" do
      children = for i <- 1..2500, do: %{child_id: :"child_#{i}"}
      req = %StopChildrenRequest{children: children}

      result = RequestManager.split(req)
      assert length(result) == 3
    end
  end

  describe "split/1 with PidsRegisterRequest" do
    test "returns single request when data <= 10000" do
      data = Map.new(1..100, fn i -> {:"child_#{i}", {%{}, [], %{}}} end)
      req = %PidsRegisterRequest{children_data: data}

      assert [^req] = RequestManager.split(req)
    end

    test "splits at 10000 threshold" do
      data = Map.new(1..20_000, fn i -> {:"child_#{i}", {%{}, [], %{}}} end)
      req = %PidsRegisterRequest{children_data: data}

      result = RequestManager.split(req)
      assert length(result) == 2

      total = Enum.map(result, &map_size(&1.children_data)) |> Enum.sum()
      assert total == 20_000
    end
  end

  describe "split/1 with PidsUnregisterRequest" do
    test "returns single request when data <= 10000" do
      data = for i <- 1..100, do: {:"child_#{i}", [node()]}
      req = %PidsUnregisterRequest{removable_cid_nodes: data}

      assert [^req] = RequestManager.split(req)
    end

    test "splits at 10000 threshold" do
      data = for i <- 1..20_000, do: {:"child_#{i}", [node()]}
      req = %PidsUnregisterRequest{removable_cid_nodes: data}

      result = RequestManager.split(req)
      assert length(result) == 2

      total = Enum.map(result, &length(&1.removable_cid_nodes)) |> Enum.sum()
      assert total == 20_000
    end
  end

  describe "split/1 with unknown struct" do
    test "returns request in list" do
      req = %{unknown: true}
      assert [^req] = RequestManager.split(req)
    end
  end

  ##############################################################################
  # request_to_opts
  ##############################################################################

  describe "request_to_opts/1" do
    test "converts request fields to keyword list" do
      req = %StartChildrenRequest{
        transaction_id: :txn_123,
        hub_id: :my_hub,
        originating_node: node(),
        reply_to: [self()],
        node: node(),
        children: [],
        options: [disable_logging: true]
      }

      opts = RequestManager.request_to_opts(req)

      assert Keyword.get(opts, :transaction_id) == :txn_123
      assert Keyword.get(opts, :hub_id) == :my_hub
      assert Keyword.get(opts, :originating_node) == node()
      assert Keyword.get(opts, :reply_to) == [self()]
      assert Keyword.get(opts, :disable_logging) == true
    end

    test "handles nil fields gracefully" do
      req = %StartChildrenRequest{
        transaction_id: nil,
        hub_id: nil,
        originating_node: nil,
        reply_to: nil,
        node: node(),
        children: [],
        options: []
      }

      opts = RequestManager.request_to_opts(req)

      refute Keyword.has_key?(opts, :transaction_id)
      refute Keyword.has_key?(opts, :hub_id)
      refute Keyword.has_key?(opts, :originating_node)
      refute Keyword.has_key?(opts, :reply_to)
    end
  end

  ##############################################################################
  # GenServer handlers
  ##############################################################################

  describe "handle_response/4" do
    test "returns noreply unchanged when operation is nil" do
      state = hub_state()
      txn_id = make_ref()

      assert {:noreply, ^state} =
               RequestManager.handle_response(state, txn_id, node(), [])
    end
  end

  describe "handle_await/3" do
    test "replies with error when operation is nil" do
      state = hub_state()
      txn_id = make_ref()
      from = {self(), make_ref()}

      assert {:reply, {:error, :pending_request_not_found}, ^state} =
               RequestManager.handle_await(state, txn_id, from)
    end
  end

  describe "handle_timeout/3" do
    test "returns noreply when operation is nil" do
      state = hub_state()
      txn_id = make_ref()
      from = {self(), make_ref()}

      assert {:noreply, ^state} =
               RequestManager.handle_timeout(state, txn_id, from)
    end
  end
end
