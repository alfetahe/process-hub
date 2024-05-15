defmodule Test.Constant.HookTest do
  use ExUnit.Case

  alias ProcessHub.Constant.Hook

  test "pre_cluster_join" do
    assert Hook.pre_cluster_join() === :pre_cluster_join_hook
  end

  test "post_cluster_join" do
    assert Hook.post_cluster_join() === :post_cluster_join_hook
  end

  test "pre_cluster_leave" do
    assert Hook.pre_cluster_leave() === :pre_cluster_leave_hook
  end

  test "post_cluster_leave" do
    assert Hook.post_cluster_leave() === :post_cluster_leave_hook
  end

  test "registry pid inserted" do
    assert Hook.registry_pid_inserted() === :registry_pid_insert_hook
  end

  test "registry pid removed" do
    assert Hook.registry_pid_removed() === :registry_pid_remove_hook
  end

  test "children migrated" do
    assert Hook.children_migrated() === :children_migrated_hook
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

  test "pre children start" do
    assert Hook.pre_children_start() === :pre_children_start_hook
  end

  test "post children start" do
    assert Hook.post_children_start() === :post_children_start_hook
  end

  test "pre children redistribution" do
    assert Hook.pre_children_redistribution() === :pre_children_redistribution_hook
  end
end
