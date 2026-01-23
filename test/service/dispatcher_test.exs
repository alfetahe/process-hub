defmodule Test.Service.DispatcherTest do
  alias ProcessHub.Service.Dispatcher

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

  test "propagate event", %{hub: hub} = _context do
    :blockade.add_handler(hub.procs.event_queue, :propagate_test)
    :blockade.add_handler(hub.procs.event_queue, :propagate_test2)

    Dispatcher.propagate_event(hub.procs.event_queue, :propagate_test, "test_data")
    Dispatcher.propagate_event(hub.procs.event_queue, :propagate_test2, "test_data2")

    assert_receive {:propagate_test, "test_data"}, @default_receive_timeout
    assert_receive {:propagate_test2, "test_data2"}, @default_receive_timeout
  end

  test "propagate stop", %{hub_id: hub_id} = _context do
    local_node = node()

    event_data = [
      {local_node,
       [
         %{
           hub_id: hub_id,
           nodes: [local_node],
           child_id: :propagate_stop_test
         }
       ]}
    ]

    Dispatcher.children_stop(hub_id, event_data, reply_to: [self()])

    assert_receive {:collect_stop_results, [propagate_stop_test: {:error, :not_found}], _node},
                   @default_receive_timeout
  end
end
