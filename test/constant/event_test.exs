defmodule Test.Constant.EventTest do
  use ExUnit.Case
  use ProcessHub.Constant.Event

  test "event cluster join" do
    assert @event_cluster_join === :cluster_join_event
  end

  test "event cluster heartbeat" do
    assert @event_cluster_heartbeat === :cluster_heartbeat_event
  end

  test "event node restarted" do
    assert @event_node_restarted === :node_restarted_event
  end

  test "event cluster leave" do
    assert @event_cluster_leave === :cluster_leave_event
  end

  test "event cluster leave batch" do
    assert @event_cluster_leave_batch === :cluster_leave_batch_event
  end

  test "event node registry broadcast" do
    assert @event_node_registry_broadcast === :node_registry_broadcast_event
  end

  test "event requests handle" do
    assert @event_requests_handle === :requests_handle_event
  end
end
