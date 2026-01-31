defmodule Test.Constant.EventTest do
  use ExUnit.Case
  use ProcessHub.Constant.Event

  test "event cluster join" do
    assert @event_cluster_join === :cluster_join_event
  end

  test "event cluster leave" do
    assert @event_cluster_leave === :cluster_leave_event
  end

  # TODO: Add other event tests.
end
