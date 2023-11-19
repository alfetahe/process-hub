defmodule Test.Constant.HookTest do
  use ExUnit.Case

  alias ProcessHub.Constant.Hook

  test "cluster_join" do
    assert Hook.cluster_join() === :cluster_join_hook
  end

  test "cluster_leave" do
    assert Hook.cluster_leave() === :cluster_leave_hook
  end

  test "registry pid inserted" do
    assert Hook.registry_pid_inserted() === :registry_pid_insert_hook
  end

  test "registry pid removed" do
    assert Hook.registry_pid_removed() === :registry_pid_remove_hook
  end

  test "child migrated" do
    assert Hook.child_migrated() === :child_migrated_hook
  end

  test "migration forwarded" do
    assert Hook.forwarded_migration() === :forwarded_migration_hook
  end

  test "priority state updated" do
    assert Hook.priority_state_updated() === :priority_state_updated_hook
  end

  test "pre nodes redistribution" do
    assert Hook.pre_nodes_redistribution() === :pre_nodes_redistribution_hook
  end

  test "post nodes redistribution" do
    assert Hook.post_nodes_redistribution() === :post_nodes_redistribution_hook
  end
end
