defmodule Test.Constant.EventTest do
  use ExUnit.Case
  use ProcessHub.Constant.Event

  test "event children registration" do
    assert @event_children_registration === :children_registration_event
  end

  test "event children unregistration" do
    assert @event_children_unregistration === :children_unregistration_event
  end

  test "event sync remote children" do
    assert @event_sync_remote_children === :sync_remote_children_event
  end

  test "event cluster join" do
    assert @event_cluster_join === :cluster_join_event
  end

  test "event cluster leave" do
    assert @event_cluster_leave === :cluster_leave_event
  end

  test "event distribute children" do
    assert @event_distribute_children === :distribute_children_event
  end

  test "event migration add" do
    assert @event_migration_add === :migration_add_event
  end
end
