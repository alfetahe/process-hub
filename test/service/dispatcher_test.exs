defmodule Test.Service.DispatcherTest do
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Utility.Name

  use ProcessHub.Constant.Event
  use ExUnit.Case

  setup_all %{} do
    Test.Helper.SetupHelper.setup_base(%{}, :dispatcher_test)
  end

  test "reply_respondents" do
    Dispatcher.reply_respondents([self()], :test_msg, :test_child, :ok, :test_node)
    Dispatcher.reply_respondents([self()], :test_msg, :test_child, :ok, :test_node)

    assert_received {:test_msg, :test_child, :ok, :test_node}, 100
    assert_received {:test_msg, :test_child, :ok, :test_node}, 100
  end

  test "propagate event local", %{hub_id: hub_id} = _context do
    :blockade.add_handler(Name.local_event_queue(hub_id), :propagate_local_test)
    :blockade.add_handler(Name.local_event_queue(hub_id), :propagate_local_test2)

    Dispatcher.propagate_event(hub_id, :propagate_local_test, "local_test_data", :local)
    Dispatcher.propagate_event(hub_id, :propagate_local_test2, "local_test_data2", :local)

    assert_receive {:propagate_local_test, "local_test_data"}, 100
    assert_receive {:propagate_local_test2, "local_test_data2"}, 100
  end

  test "propagate event global", %{hub_id: hub_id} = _context do
    :blockade.add_handler(Name.global_event_queue(hub_id), :propagate_global_test)
    :blockade.add_handler(Name.global_event_queue(hub_id), :propagate_global_test2)

    Dispatcher.propagate_event(hub_id, :propagate_global_test, "global_test_data", :global)
    Dispatcher.propagate_event(hub_id, :propagate_global_test2, "global_test_data2", :global)

    assert_receive {:propagate_global_test, "global_test_data"}, 100
    assert_receive {:propagate_global_test2, "global_test_data2"}, 100
  end

  test "propagate init", %{hub_id: hub_id} = _context do
    local_node = node()

    event_data = [
      {local_node,
       [
         %{
           hub_id: hub_id,
           nodes: [local_node],
           child_id: :propagate_init_test,
           child_spec: %{
             id: :propagate_init_test,
             start: {Test.Helper.TestServer, :start_link, [%{name: :propagate_init_test}]}
           },
           reply_to: [self()]
         }
       ]}
    ]

    Dispatcher.children_start(hub_id, event_data)

    assert_receive {:child_start_resp, :propagate_init_test, _, _}, 100
  end

  test "propagate stop", %{hub_id: hub_id} = _context do
    local_node = node()

    event_data = [
      {local_node,
       [
         %{
           hub_id: hub_id,
           nodes: [local_node],
           child_id: :propagate_stop_test,
           reply_to: [self()]
         }
       ]}
    ]

    Dispatcher.children_stop(hub_id, event_data)

    assert_receive {:child_stop_resp, :propagate_stop_test, _, _}, 100
  end
end
