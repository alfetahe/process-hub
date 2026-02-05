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

    assert_received {:test_msg, :test_child, :ok, :test_node}, @default_receive_timeout
    assert_received {:test_msg, :test_child, :ok, :test_node}, @default_receive_timeout
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
end
