defmodule Test.Service.RequestManagerTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Service.RequestManager
  alias ProcessHub.Request.Handler.StartChildrenRequest
  alias ProcessHub.Request.Handler.StopChildrenRequest
  alias ProcessHub.Request.Handler.PidsRegisterRequest
  alias ProcessHub.Request.Handler.PidsUnregisterRequest
  alias ProcessHub.Hub

  setup_all do
    Test.Helper.SetupHelper.setup_base(%{}, :request_manager_test_hub)
  end

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
  # GenServer handlers
  ##############################################################################

  describe "handle_response/4" do
    test "returns noreply unchanged when operation is nil" do
      state = hub_state()
      txn_id = make_ref()

      assert {:noreply, ^state} =
               RequestManager.handle_response(state, txn_id, node(), [])
    end

    test "completes and removes operation when all nodes responded" do
      sub_req = %StartChildrenRequest{
        node: node(),
        results: nil,
        status: :dispatched,
        children: [%{child_id: :child1}]
      }

      op = make_operation(nodes_data: [{node(), [%{child_id: :child1}]}])
      op = %{op | sub_requests: [sub_req]}
      state = hub_state(%{op.transaction_id => op})

      assert {:noreply, new_state} =
               RequestManager.handle_response(state, op.transaction_id, node(), [
                 {:child1, {:ok, self()}}
               ])

      assert new_state.pending_operations == %{}
    end

    test "keeps operation pending when not all nodes responded" do
      sub1 = %StartChildrenRequest{
        node: :node1,
        results: nil,
        status: :dispatched,
        children: [%{child_id: :child1}]
      }

      sub2 = %StartChildrenRequest{
        node: :node2,
        results: nil,
        status: :dispatched,
        children: [%{child_id: :child2}]
      }

      op = make_operation(nodes_data: [{:node1, []}, {:node2, []}])
      op = %{op | sub_requests: [sub1, sub2]}
      state = hub_state(%{op.transaction_id => op})

      assert {:noreply, new_state} =
               RequestManager.handle_response(state, op.transaction_id, :node1, [
                 {:child1, {:ok, self()}}
               ])

      updated_op = new_state.pending_operations[op.transaction_id]
      assert MapSet.member?(updated_op.completed_nodes, :node1)
      refute MapSet.member?(updated_op.completed_nodes, :node2)
    end

    test "retains an awaitable result until a late await claims it" do
      sub_req = %StartChildrenRequest{
        node: node(),
        results: nil,
        status: :dispatched,
        children: [%{child_id: :child1}]
      }

      op = make_operation(nodes_data: [{node(), [%{child_id: :child1}]}])
      op = %{op | sub_requests: [sub_req], options: [awaitable: true, timeout: 0]}
      state = hub_state(%{op.transaction_id => op})

      {:noreply, retained} =
        RequestManager.handle_response(state, op.transaction_id, node(), [
          {:child1, {:ok, self()}}
        ])

      held = retained.pending_operations[op.transaction_id]
      assert %ProcessHub.StartResult{status: :ok} = held.result
      # Retention is bounded by the future timeout plus the await grace period.
      assert held.expires_at <= System.monotonic_time(:millisecond) + 1000

      # Split requests reply once per chunk under the same id; the result is final.
      assert {:noreply, ^retained} =
               RequestManager.handle_response(retained, op.transaction_id, node(), [
                 {:child2, {:ok, self()}}
               ])

      assert {:reply, %ProcessHub.StartResult{started: [{:child1, _}]}, awaited} =
               RequestManager.handle_await(retained, op.transaction_id, {self(), make_ref()})

      assert awaited.pending_operations == %{}
    end

    test "replies to awaiter on complete" do
      ref = make_ref()
      from = {self(), ref}

      sub_req = %StartChildrenRequest{
        node: node(),
        results: nil,
        status: :dispatched,
        children: [%{child_id: :child1}]
      }

      op = make_operation(nodes_data: [{node(), []}])
      op = %{op | sub_requests: [sub_req], awaiter: from}
      state = hub_state(%{op.transaction_id => op})

      assert {:noreply, new_state} =
               RequestManager.handle_response(state, op.transaction_id, node(), [
                 {:child1, {:ok, self()}}
               ])

      assert new_state.pending_operations == %{}
      assert_receive {^ref, %ProcessHub.StartResult{}}
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

    test "replies immediately when all nodes responded" do
      sub_req = %StartChildrenRequest{
        node: node(),
        results: [{:child1, {:ok, self()}}],
        status: :completed,
        children: []
      }

      op = make_operation(nodes_data: [{node(), []}])
      op = %{op | sub_requests: [sub_req], completed_nodes: MapSet.new([node()])}
      state = hub_state(%{op.transaction_id => op})
      from = {self(), make_ref()}

      assert {:reply, %ProcessHub.StartResult{status: :ok}, new_state} =
               RequestManager.handle_await(state, op.transaction_id, from)

      assert new_state.pending_operations == %{}
    end

    test "replies immediately when timeout is 0" do
      sub_req = %StartChildrenRequest{
        node: :node1,
        results: nil,
        status: :dispatched,
        children: [%{child_id: :child1}]
      }

      op = make_operation(nodes_data: [{:node1, []}, {:node2, []}])
      op = %{op | sub_requests: [sub_req], options: [timeout: 0]}
      state = hub_state(%{op.transaction_id => op})
      from = {self(), make_ref()}

      assert {:reply, %ProcessHub.StartResult{}, new_state} =
               RequestManager.handle_await(state, op.transaction_id, from)

      assert new_state.pending_operations == %{}
    end

    test "sets awaiter and returns noreply when waiting" do
      sub_req = %StartChildrenRequest{
        node: :node1,
        results: nil,
        status: :dispatched,
        children: [%{child_id: :child1}]
      }

      op = make_operation(nodes_data: [{:node1, []}, {:node2, []}])
      op = %{op | sub_requests: [sub_req], options: [timeout: 5000]}
      state = hub_state(%{op.transaction_id => op})
      from = {self(), make_ref()}

      assert {:noreply, new_state} =
               RequestManager.handle_await(state, op.transaction_id, from)

      updated_op = new_state.pending_operations[op.transaction_id]
      assert updated_op.awaiter == from
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

    test "replies and removes when awaiter matches" do
      ref = make_ref()
      from = {self(), ref}

      sub_req = %StartChildrenRequest{
        node: node(),
        results: nil,
        status: :dispatched,
        children: [%{child_id: :child1}]
      }

      op = make_operation(nodes_data: [{node(), []}])
      op = %{op | sub_requests: [sub_req], awaiter: from}
      state = hub_state(%{op.transaction_id => op})

      assert {:noreply, new_state} =
               RequestManager.handle_timeout(state, op.transaction_id, from)

      assert new_state.pending_operations == %{}
      assert_receive {^ref, %ProcessHub.StartResult{}}
    end

    test "does not reply when awaiter does not match" do
      from_stored = {self(), make_ref()}
      from_called = {self(), make_ref()}

      op = make_operation()
      op = %{op | awaiter: from_stored}
      state = hub_state(%{op.transaction_id => op})

      assert {:noreply, ^state} =
               RequestManager.handle_timeout(state, op.transaction_id, from_called)
    end
  end

  ##############################################################################
  # request_to_opts
  ##############################################################################

  describe "request_to_opts/1" do
    test "includes all fields when present" do
      request = %StartChildrenRequest{
        transaction_id: make_ref(),
        hub_id: :test_hub,
        originating_node: node(),
        reply_to: [self()],
        options: [some_opt: true]
      }

      opts = RequestManager.request_to_opts(request)

      assert Keyword.get(opts, :transaction_id) == request.transaction_id
      assert Keyword.get(opts, :hub_id) == :test_hub
      assert Keyword.get(opts, :originating_node) == node()
      assert Keyword.get(opts, :reply_to) == [self()]
      assert Keyword.get(opts, :some_opt) == true
    end

    test "excludes nil transaction_id, originating_node, and reply_to" do
      request = %StartChildrenRequest{
        transaction_id: nil,
        hub_id: :test_hub,
        originating_node: nil,
        reply_to: nil,
        options: [some_opt: true]
      }

      opts = RequestManager.request_to_opts(request)

      refute Keyword.has_key?(opts, :transaction_id)
      refute Keyword.has_key?(opts, :originating_node)
      refute Keyword.has_key?(opts, :reply_to)
      assert Keyword.get(opts, :hub_id) == :test_hub
      assert Keyword.get(opts, :some_opt) == true
    end
  end

  ##############################################################################
  # with_partition_check
  ##############################################################################

  describe "with_partition_check/2" do
    test "executes function when not partitioned" do
      reg_name = :"test_not_part_reg_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Registry.start_link(keys: :unique, name: reg_name)
      Registry.register(reg_name, "dist_sup", nil)

      fake_hub = %Hub{hub_id: :fake_hub, procs: %{system_registry: reg_name}}

      result = RequestManager.with_partition_check(fake_hub, fn -> :my_result end)
      assert result == :my_result
    end

    test "returns {:error, :partitioned} when partitioned" do
      reg_name = :"test_part_reg_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Registry.start_link(keys: :unique, name: reg_name)

      fake_hub = %Hub{hub_id: :fake_hub, procs: %{system_registry: reg_name}}

      result = RequestManager.with_partition_check(fake_hub, fn -> :should_not_run end)
      assert result == {:error, :partitioned}
    end
  end

  ##############################################################################
  # populate_forward
  ##############################################################################

  describe "populate_forward/3" do
    test "adds child_data to a single target node" do
      child = %{child_id: :child1}
      result = RequestManager.populate_forward([], [:node1], child)

      assert result == [node1: [child]]
    end

    test "groups child_data across multiple target nodes" do
      child = %{child_id: :child1}
      result = RequestManager.populate_forward([], [:node1, :node2], child)

      assert Keyword.get(result, :node1) == [child]
      assert Keyword.get(result, :node2) == [child]
    end

    test "accumulates children for the same node" do
      child1 = %{child_id: :child1}
      child2 = %{child_id: :child2}

      result =
        []
        |> RequestManager.populate_forward([:node1], child1)
        |> RequestManager.populate_forward([:node1], child2)

      assert Keyword.get(result, :node1) == [child2, child1]
    end

    test "preserves existing forward data" do
      existing = [node1: [%{child_id: :existing}]]
      child = %{child_id: :new}

      result = RequestManager.populate_forward(existing, [:node2], child)

      assert Keyword.get(result, :node1) == [%{child_id: :existing}]
      assert Keyword.get(result, :node2) == [child]
    end

    test "returns unchanged forward data when target_nodes is empty" do
      existing = [node1: [%{child_id: :child1}]]
      result = RequestManager.populate_forward(existing, [], %{child_id: :child2})

      assert result == existing
    end
  end

  ##############################################################################
  # Constructor
  ##############################################################################

  describe "new/4" do
    test "creates operation with correct fields", %{hub: hub} do
      nodes_data = [{node(), [%{child_id: :c1}]}]
      op = RequestManager.new(hub, StartChildrenRequest, nodes_data, [])

      assert op.hub_id == hub.hub_id
      assert op.handler == StartChildrenRequest
      assert op.nodes_data == nodes_data
      assert is_reference(op.transaction_id)
      assert op.completed_nodes == MapSet.new()
      assert op.sub_requests == []
      assert %ProcessHub.Future{} = op.future
      assert op.future.action == :start
    end

    test "sets future action to :stop for StopChildrenRequest", %{hub: hub} do
      op = RequestManager.new(hub, StopChildrenRequest, [{node(), []}], [])
      assert op.future.action == :stop
    end

    test "respects custom request_timeout", %{hub: hub} do
      before = System.monotonic_time(:millisecond)
      op = RequestManager.new(hub, StartChildrenRequest, [], request_timeout: 30_000)
      after_ms = System.monotonic_time(:millisecond)

      assert op.expires_at >= before + 30_000
      assert op.expires_at <= after_ms + 30_000
    end

    test "passes options through", %{hub: hub} do
      op = RequestManager.new(hub, StartChildrenRequest, [], my_opt: :val)
      assert Keyword.get(op.options, :my_opt) == :val
    end
  end

  ##############################################################################
  # compose_sub_requests
  ##############################################################################

  describe "compose_sub_requests/1" do
    test "returns error for empty nodes_data" do
      op = make_operation(nodes_data: [])
      assert {:error, :no_children} = RequestManager.compose_sub_requests(op)
    end

    test "creates sub_requests per target node", %{hub: hub} do
      children = [
        %{child_id: :c1, child_spec: %{id: :c1, start: {Agent, :start_link, [fn -> nil end]}}}
      ]

      nodes_data = [{node(), children}]
      op = RequestManager.new(hub, StartChildrenRequest, nodes_data, [])

      assert {:ok, updated} = RequestManager.compose_sub_requests(op)
      assert length(updated.sub_requests) == 1
      [sub] = updated.sub_requests
      assert sub.node == node()
    end

    test "creates one sub_request per node", %{hub: hub} do
      c1 = [%{child_id: :c1}]
      c2 = [%{child_id: :c2}]
      nodes_data = [{:node1, c1}, {:node2, c2}]
      op = RequestManager.new(hub, StartChildrenRequest, nodes_data, [])

      assert {:ok, updated} = RequestManager.compose_sub_requests(op)
      assert length(updated.sub_requests) == 2
      nodes = Enum.map(updated.sub_requests, & &1.node) |> Enum.sort()
      assert nodes == [:node1, :node2]
    end
  end

  ##############################################################################
  # send_response
  ##############################################################################

  describe "send_response/3" do
    test "returns :skip when hub_id is nil" do
      opts = [transaction_id: make_ref()]
      assert :skip = RequestManager.send_response(:start_response, opts, [])
    end

    test "returns :skip when transaction_id is nil" do
      opts = [hub_id: :some_hub]
      assert :skip = RequestManager.send_response(:start_response, opts, [])
    end

    test "returns :skip when both are nil" do
      assert :skip = RequestManager.send_response(:start_response, [], [])
    end
  end

  ##############################################################################
  # load_strategies
  ##############################################################################

  describe "load_strategies/1" do
    test "loads all four strategies", %{hub: hub} do
      strats = RequestManager.load_strategies(hub)

      assert Map.has_key?(strats, :sync)
      assert Map.has_key?(strats, :dist)
      assert Map.has_key?(strats, :redun)
      assert Map.has_key?(strats, :migr)
      assert strats.dist != nil
      assert strats.sync != nil
    end
  end

  ##############################################################################
  # Factory functions (require real hub)
  ##############################################################################

  describe "migration_request/4" do
    test "creates StartChildrenRequest for migration", %{hub: hub} do
      child_spec = %{id: :migr_child, start: {Test.Helper.TestServer, :start_link, [%{}]}}
      children_data = [{child_spec, %{some: :meta}}]

      req = RequestManager.migration_request(hub, :target_node, children_data)

      assert %StartChildrenRequest{} = req
      assert req.hub_id == hub.hub_id
      assert req.originating_node == nil
      assert req.node == :target_node
      assert length(req.children) == 1
      assert hd(req.children).child_id == :migr_child
      assert hd(req.children).migration == true
      assert req.request_signature != nil
    end
  end

  describe "contraction_request/3" do
    test "creates StartChildrenRequest for contraction", %{hub: hub} do
      child_spec = %{id: :contr_child, start: {Test.Helper.TestServer, :start_link, [%{}]}}
      children_data = [{child_spec, %{some: :meta}}]

      req = RequestManager.contraction_request(hub, children_data)

      assert %StartChildrenRequest{} = req
      assert req.hub_id == hub.hub_id
      assert req.originating_node == nil
      assert req.node == node()
      assert length(req.children) == 1
      assert hd(req.children).child_id == :contr_child
      assert hd(req.children).migration == true
      assert req.request_signature != nil
    end
  end
end
