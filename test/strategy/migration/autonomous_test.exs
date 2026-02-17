defmodule Test.Strategy.Migration.AutonomousTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Migration.Autonomous
  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook

  setup do
    hub_id = :"test_auto_#{:erlang.unique_integer([:positive])}"
    misc_storage = :ets.new(hub_id, [:set, :public, :named_table])
    hook_storage = :ets.new(:"hook_#{hub_id}", [:set, :public])

    hub = %ProcessHub.Hub{
      hub_id: hub_id,
      storage: %{misc: misc_storage, hook: hook_storage}
    }

    on_exit(fn ->
      if :ets.whereis(hub_id) != :undefined, do: :ets.delete(hub_id)

      try do
        :ets.delete(hook_storage)
      rescue
        _ -> :ok
      end
    end)

    %{hub: hub, hub_id: hub_id}
  end

  describe "struct" do
    test "has no fields" do
      auto = %Autonomous{}
      assert auto == %Autonomous{}
      assert Map.keys(auto) -- [:__struct__] == []
    end
  end

  describe "init/2" do
    test "returns strategy unchanged", %{hub: hub} do
      strategy = %Autonomous{}
      result = MigrationStrategy.init(strategy, hub)
      assert result == strategy
    end

    test "does not register any hooks", %{hub: hub} do
      strategy = %Autonomous{}
      MigrationStrategy.init(strategy, hub)

      assert HookManager.registered_handlers(hub.storage.hook, Hook.coordinator_shutdown()) == []
      assert HookManager.registered_handlers(hub.storage.hook, Hook.post_children_start()) == []
    end
  end

  describe "reconcile/3" do
    test "empty cid_node_map produces no side effects", %{hub: hub} do
      handler = %{calculated_cids: %{}, sync_strat: nil}
      result = Autonomous.reconcile(hub, handler, %{})
      assert result == handler
    end

    test "returns handler unchanged when no action needed", %{hub: hub} do
      handler = %{calculated_cids: %{}, sync_strat: nil}
      # No registry entries match the cid_node_map, so nothing to stop or start.
      cid_node_map = %{child1: [:nonexistent@node]}
      result = Autonomous.reconcile(hub, handler, cid_node_map)
      assert result == handler
    end

    test "children already in correct place — no stop or start", %{hub: hub, hub_id: hub_id} do
      child_spec = %{id: :child1, start: {Agent, :start_link, [fn -> %{} end]}}

      # Insert registry entry: child1 is running locally.
      :ets.insert(hub_id, {:child1, {child_spec, [{node(), self()}], %{}}})

      handler = %{calculated_cids: %{}, sync_strat: nil}
      # cid_node_map says child1 belongs on the local node — already correct.
      cid_node_map = %{child1: [node()]}

      result = Autonomous.reconcile(hub, handler, cid_node_map)
      assert result == handler
    end

    test "child not in registry — skips start even if primary is local", %{hub: hub} do
      handler = %{calculated_cids: %{}, sync_strat: nil}
      # child2 is not in the registry at all, so no spec to start from.
      cid_node_map = %{child2: [node()]}

      result = Autonomous.reconcile(hub, handler, cid_node_map)
      assert result == handler
    end

    test "child on remote node only — no local action needed", %{hub: hub, hub_id: hub_id} do
      child_spec = %{id: :child3, start: {Agent, :start_link, [fn -> %{} end]}}
      remote_node = :remote@node

      # child3 is running on a remote node, not locally.
      :ets.insert(hub_id, {:child3, {child_spec, [{remote_node, self()}], %{}}})

      handler = %{calculated_cids: %{}, sync_strat: nil}
      # Primary is the remote node — no local stop or start.
      cid_node_map = %{child3: [remote_node]}

      result = Autonomous.reconcile(hub, handler, cid_node_map)
      assert result == handler
    end
  end

  describe "handle_topology_contraction/4" do
    test "empty calculated_cids returns handler unchanged", %{hub: hub} do
      handler = %{calculated_cids: %{}, sync_strat: nil}
      result = MigrationStrategy.handle_topology_contraction(%Autonomous{}, hub, [], handler)
      assert result == handler
    end

    test "uses pre-computed calculated_cids from handler", %{hub: hub, hub_id: hub_id} do
      remote_node = :remote@node
      child_spec = %{id: :child_c1, start: {Agent, :start_link, [fn -> %{} end]}}

      # Registry has the child on a remote node.
      :ets.insert(hub_id, {:child_c1, {child_spec, [{remote_node, self()}], %{}}})

      # calculated_cids says child_c1 primary is remote — no local action needed.
      handler = %{
        calculated_cids: %{child_c1: [remote_node]},
        sync_strat: nil
      }

      result =
        MigrationStrategy.handle_topology_contraction(%Autonomous{}, hub, [:dead@node], handler)

      assert result == handler
    end
  end
end
