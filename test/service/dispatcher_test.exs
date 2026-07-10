defmodule Test.Service.DispatcherTest do
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Request.Handler.PidsUnregisterRequest

  use ProcessHub.Constant.Event
  use ExUnit.Case

  @default_receive_timeout 100

  setup_all %{} do
    Test.Helper.SetupHelper.setup_base(%{}, :dispatcher_test)
  end

  test "reply_respondents" do
    Dispatcher.reply_respondents([self()], :test_msg, :test_child, :ok, :test_node)
    Dispatcher.reply_respondents([self()], :test_msg, :test_child, :ok, :test_node)

    assert_received {:test_msg, :test_child, :ok, :test_node}
    assert_received {:test_msg, :test_child, :ok, :test_node}
  end

  test "dispatch_event", %{hub: hub} = _context do
    :blockade.add_handler(hub.procs.event_queue, :dispatch_test)
    :blockade.add_handler(hub.procs.event_queue, :dispatch_test2)

    Dispatcher.dispatch_event(hub.procs.event_queue, :dispatch_test, "test_data")
    Dispatcher.dispatch_event(hub.procs.event_queue, :dispatch_test2, "test_data2")

    assert_receive {:dispatch_test, "test_data"}, @default_receive_timeout
    assert_receive {:dispatch_test2, "test_data2"}, @default_receive_timeout
  end

  test "propagate_event/3 propagates request to event queue", %{hub: hub} do
    :blockade.add_handler(hub.procs.event_queue, @event_requests_handle)

    request = PidsUnregisterRequest.new([{:test_child, [node()]}])

    assert :ok = Dispatcher.propagate_event(hub, request, members: :global)

    assert_receive {@event_requests_handle, requests}, @default_receive_timeout
    assert is_list(requests)
    assert length(requests) == 1
  end

  test "children_start dispatches start requests preserving hub_id and node", %{hub: hub} do
    :blockade.add_handler(hub.procs.event_queue, @event_requests_handle)

    child_spec = %{
      id: :dispatch_start_child,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dispatch_start_child}]}
    }

    request = %ProcessHub.Request.Handler.StartChildrenRequest{
      transaction_id: :test_tx_start,
      hub_id: hub.hub_id,
      originating_node: node(),
      reply_to: self(),
      node: node(),
      children: [%{child_spec: child_spec, child_id: :dispatch_start_child, nodes: [node()]}],
      request_signature: nil
    }

    assert :ok = Dispatcher.children_start(hub, [request])

    assert_receive {@event_requests_handle, [dispatched_req]}, @default_receive_timeout

    # Verify the dispatched request preserves critical routing fields
    assert dispatched_req.hub_id === hub.hub_id
    assert dispatched_req.node === node()
    assert dispatched_req.originating_node === node()
    assert dispatched_req.reply_to === self()
    assert length(dispatched_req.children) === 1
  end

  test "children_stop dispatches stop requests preserving hub_id and node", %{hub: hub} do
    :blockade.add_handler(hub.procs.event_queue, @event_requests_handle)

    request = %ProcessHub.Request.Handler.StopChildrenRequest{
      transaction_id: :test_tx_stop,
      hub_id: hub.hub_id,
      originating_node: node(),
      reply_to: self(),
      node: node(),
      children: [%{child_id: :dispatch_stop_child, nodes: [node()]}]
    }

    assert :ok = Dispatcher.children_stop(hub, [request])

    assert_receive {@event_requests_handle, [dispatched_req]}, @default_receive_timeout

    assert dispatched_req.hub_id === hub.hub_id
    assert dispatched_req.node === node()
    assert dispatched_req.reply_to === self()
    assert length(dispatched_req.children) === 1
    assert List.first(dispatched_req.children).child_id === :dispatch_stop_child
  end

  test "propagate_event/2 uses default opts", %{hub: hub} do
    :blockade.add_handler(hub.procs.event_queue, @event_requests_handle)

    request = PidsUnregisterRequest.new([{:test_child_default, [node()]}])

    assert :ok = Dispatcher.propagate_event(hub, request)

    assert_receive {@event_requests_handle, requests}, @default_receive_timeout
    assert is_list(requests)
    assert length(requests) == 1
  end

  test "children_start groups requests by target node into single dispatch", %{hub: hub} do
    :blockade.add_handler(hub.procs.event_queue, @event_requests_handle)

    request1 = %ProcessHub.Request.Handler.StartChildrenRequest{
      transaction_id: :grp_tx1,
      hub_id: hub.hub_id,
      originating_node: node(),
      reply_to: self(),
      node: node(),
      children: [%{child_spec: %{id: :grp1}, child_id: :grp1, nodes: [node()]}],
      request_signature: nil
    }

    request2 = %ProcessHub.Request.Handler.StartChildrenRequest{
      transaction_id: :grp_tx2,
      hub_id: hub.hub_id,
      originating_node: node(),
      reply_to: self(),
      node: node(),
      children: [%{child_spec: %{id: :grp2}, child_id: :grp2, nodes: [node()]}],
      request_signature: nil
    }

    # Both requests target the same node — should merge into one dispatch
    assert :ok = Dispatcher.children_start(hub, [request1, request2])

    assert_receive {@event_requests_handle, dispatched}, @default_receive_timeout
    assert length(dispatched) === 2

    # Verify both transaction IDs are present (both requests dispatched)
    tx_ids = Enum.map(dispatched, & &1.transaction_id)
    assert :grp_tx1 in tx_ids
    assert :grp_tx2 in tx_ids
  end
end
