defmodule Test.Request.Handler.StopChildrenRequestTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Request.Handler.StopChildrenRequest
  alias ProcessHub.Service.RequestManager
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Utility.Bag

  @hub_id :stop_req_test_hub

  setup_all context do
    Test.Helper.SetupHelper.setup_base(context, @hub_id)
  end

  defp make_operation(opts) do
    %RequestManager{
      transaction_id: Keyword.get(opts, :transaction_id, make_ref()),
      hub_id: Keyword.get(opts, :hub_id, @hub_id),
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
      op = make_operation(options: [reply_to: [self()], custom_opt: true])

      req = StopChildrenRequest.new(op, :target_node, [%{child_id: :c1}])

      assert req.transaction_id == op.transaction_id
      assert req.hub_id == @hub_id
      assert req.originating_node == node()
      assert req.reply_to == [self()]
      assert req.node == :target_node
      assert req.children == [%{child_id: :c1}]
      assert req.status == :dispatched
      # Routing opts stripped from passthrough options
      assert Keyword.get(req.options, :custom_opt) == true
      refute Keyword.has_key?(req.options, :reply_to)
    end
  end

  describe "response_type/0" do
    test "returns :operation_response" do
      assert StopChildrenRequest.response_type() == :operation_response
    end
  end

  describe "build_node_response/1" do
    test "with map format produces :ok results" do
      children = [%{child_id: :child1}, %{child_id: :child2}]

      result = StopChildrenRequest.build_node_response(children)

      assert length(result) == 2
      assert {:child1, :ok} in result
      assert {:child2, :ok} in result
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

    test "handles nil results as no_response errors" do
      sub_req = %StopChildrenRequest{
        node: :node1,
        results: nil,
        children: [%{child_id: :child1}]
      }

      op = %RequestManager{sub_requests: [sub_req], options: []}
      result = StopChildrenRequest.aggregate_results(op)

      assert result.status == :error
      assert {:child1, {:error, :no_response}} in result.errors
    end

    test "handles {:error, reason} results" do
      sub_req = %StopChildrenRequest{
        node: :node1,
        results: [{:child1, {:error, :not_found}}, {:child2, :ok}],
        children: []
      }

      op = %RequestManager{sub_requests: [sub_req], options: []}
      result = StopChildrenRequest.aggregate_results(op)

      assert result.status == :error
      assert {:child1, :not_found} in result.errors
      assert {:child2, [:node1]} in result.stopped
    end

    test "handles non-standard error results" do
      sub_req = %StopChildrenRequest{
        node: :node1,
        results: [{:child1, :some_unexpected_error}],
        children: []
      }

      op = %RequestManager{sub_requests: [sub_req], options: []}
      result = StopChildrenRequest.aggregate_results(op)

      assert result.status == :error
      assert {:child1, :some_unexpected_error} in result.errors
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

  describe "execute/2 forwarding" do
    test "terminates child locally when it exists on this node", %{hub: hub} do
      child_id = :"local_stop_#{System.unique_integer([:positive])}"
      child_spec = %{id: child_id, start: {Agent, :start_link, [fn -> :ok end]}}

      # Start the child through ProcessHub and await registration
      {:ok, future} =
        ProcessHub.start_children(@hub_id, [child_spec], awaitable: true, timeout: 5000)

      ProcessHub.Future.await(future)

      request = %StopChildrenRequest{
        transaction_id: make_ref(),
        hub_id: @hub_id,
        originating_node: node(),
        reply_to: nil,
        node: node(),
        children: [%{child_id: child_id}],
        options: [],
        status: :dispatched
      }

      assert :ok = StopChildrenRequest.execute(request, hub)

      # Wait for child to be removed from registry
      assert poll_until(fn -> ProcessRegistry.lookup(@hub_id, child_id) == nil end)
    end

    test "treats child not in registry as already stopped", %{hub: hub} do
      child_id = :"gone_child_#{System.unique_integer([:positive])}"

      # Ensure child is NOT in registry
      assert ProcessRegistry.lookup(@hub_id, child_id) == nil

      request = %StopChildrenRequest{
        transaction_id: make_ref(),
        hub_id: @hub_id,
        originating_node: node(),
        reply_to: nil,
        node: node(),
        children: [%{child_id: child_id}],
        options: [],
        status: :dispatched
      }

      # Should succeed without error — already-stopped children produce :ok response
      assert :ok = StopChildrenRequest.execute(request, hub)
    end

    test "forwards child to correct node when registry points elsewhere", %{hub: hub} do
      child_id = :"remote_child_#{System.unique_integer([:positive])}"
      fake_remote_node = :"fake_remote@127.0.0.1"
      fake_pid = spawn(fn -> Process.sleep(:infinity) end)

      child_spec = %{id: child_id, start: {Agent, :start_link, [fn -> :ok end]}}

      # Insert into registry pointing to a fake remote node (not local)
      ProcessRegistry.insert(@hub_id, child_spec, [{fake_remote_node, fake_pid}])

      # Register a hook to verify forwarding happens
      hook_handler = Bag.recv_hook(:stop_forward_hook, self())
      HookManager.register_handler(hub.storage.hook, Hook.forwarded_migration(), hook_handler)

      request = %StopChildrenRequest{
        transaction_id: make_ref(),
        hub_id: @hub_id,
        originating_node: node(),
        reply_to: nil,
        node: node(),
        children: [%{child_id: child_id}],
        options: [],
        status: :dispatched
      }

      # Execute will try to forward to the fake remote node.
      # The dispatch to a non-existent node may fail, but the hook should fire
      # and execute should not crash.
      try do
        StopChildrenRequest.execute(request, hub)
      catch
        _, _ -> :ok
      end

      # Verify the forwarded_migration hook was dispatched with the forward data
      assert_receive {:stop_forward_hook, forward_data}, 2000
      assert is_list(forward_data)

      # forward_data is a keyword list [{node, [child_data, ...]}]
      {target_node, children} = List.first(forward_data)
      assert target_node == fake_remote_node
      assert Enum.any?(children, fn c -> c.child_id == child_id end)

      # Cleanup
      Process.exit(fake_pid, :kill)
      ProcessRegistry.delete(@hub_id, child_id)
    end

    test "does not forward to nodes that already received the original request", %{hub: hub} do
      child_id = :"no_reforward_#{System.unique_integer([:positive])}"
      fake_pid = spawn(fn -> Process.sleep(:infinity) end)

      child_spec = %{id: child_id, start: {Agent, :start_link, [fn -> :ok end]}}

      # Insert into registry pointing to current node (which is request.node)
      # This means the child is "on this node" per registry — should be local
      ProcessRegistry.insert(@hub_id, child_spec, [{node(), fake_pid}])

      hook_handler = Bag.recv_hook(:no_reforward_hook, self())
      HookManager.register_handler(hub.storage.hook, Hook.forwarded_migration(), hook_handler)

      request = %StopChildrenRequest{
        transaction_id: make_ref(),
        hub_id: @hub_id,
        originating_node: node(),
        reply_to: nil,
        node: node(),
        children: [%{child_id: child_id}],
        options: [],
        status: :dispatched
      }

      StopChildrenRequest.execute(request, hub)

      # No forwarding should happen — child is local
      refute_receive {:no_reforward_hook, _}, 500

      # Cleanup
      Process.exit(fake_pid, :kill)
      ProcessRegistry.delete(@hub_id, child_id)
    end
  end

  defp poll_until(fun, timeout \\ 2000, interval \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.() do
        :done
      else
        if System.monotonic_time(:millisecond) > deadline,
          do: :timeout,
          else: Process.sleep(interval)
      end
    end)
    |> Enum.find(&(&1 != nil)) == :done
  end
end
