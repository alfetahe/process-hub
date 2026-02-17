defmodule Test.Constant.HookTest do
  use ExUnit.Case

  alias ProcessHub.Constant.Hook

  test "pre_node_join" do
    assert Hook.pre_node_join() === :pre_node_join_hook
  end

  test "post_node_join" do
    assert Hook.post_node_join() === :post_node_join_hook
  end

  test "pre_node_leave" do
    assert Hook.pre_node_leave() === :pre_node_leave_hook
  end

  test "post_node_leave" do
    assert Hook.post_node_leave() === :post_node_leave_hook
  end

  test "child registered" do
    assert Hook.child_registered() === :child_registered_hook
  end

  test "child unregistered" do
    assert Hook.child_unregistered() === :child_unregistered_hook
  end

  test "migration completed" do
    assert Hook.migration_completed() === :migration_completed_hook
  end

  test "children forwarded" do
    assert Hook.children_forwarded() === :children_forwarded_hook
  end

  test "pre redistribution" do
    assert Hook.pre_redistribution() === :pre_redistribution_hook
  end

  test "post redistribution" do
    assert Hook.post_redistribution() === :post_redistribution_hook
  end

  test "pre children start" do
    assert Hook.pre_children_start() === :pre_children_start_hook
  end

  test "post children start" do
    assert Hook.post_children_start() === :post_children_start_hook
  end

  test "pre children redistribution" do
    assert Hook.pre_children_redistribution() === :pre_children_redistribution_hook
  end

  test "coordinator shutdown" do
    assert Hook.coordinator_shutdown() === :coordinator_shutdown_hook
  end

  test "child pid updated" do
    assert Hook.child_pid_updated() === :child_pid_updated_hook
  end

  test "child data alter" do
    assert Hook.child_data_alter() === :child_data_alter_hook
  end

  test "handover delivered" do
    assert Hook.handover_delivered() === :handover_delivered_hook
  end

  test "scoreboard updated" do
    assert Hook.scoreboard_updated() === :scoreboard_updated_hook
  end
end
