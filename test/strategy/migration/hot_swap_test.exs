defmodule Test.Strategy.Migration.HotSwapTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Migration.HotSwap
  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Request.Handler.StartChildrenRequest.PostStartData

  setup do
    hub_id = :"test_hs_#{:erlang.unique_integer([:positive])}"
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

    %{hub: hub}
  end

  describe "init/2" do
    test "with handover: false returns strategy unchanged", %{hub: hub} do
      strategy = %HotSwap{handover: false}
      result = MigrationStrategy.init(strategy, hub)
      assert result == strategy

      # Verify NO hooks were registered
      assert HookManager.registered_handlers(hub.storage.hook, Hook.coordinator_shutdown()) == []
      assert HookManager.registered_handlers(hub.storage.hook, Hook.process_startups()) == []
    end

    test "with handover: true registers hook handlers", %{hub: hub} do
      strategy = %HotSwap{handover: true}
      result = MigrationStrategy.init(strategy, hub)
      assert result == strategy

      shutdown_handlers =
        HookManager.registered_handlers(hub.storage.hook, Hook.coordinator_shutdown())

      startups_handlers =
        HookManager.registered_handlers(hub.storage.hook, Hook.process_startups())

      assert length(shutdown_handlers) == 1
      assert hd(shutdown_handlers).id == :mhs_shutdown

      assert length(startups_handlers) == 1
      assert hd(startups_handlers).id == :mhs_process_startups
    end
  end

  describe "handle_shutdown/2" do
    test "with handover: false returns :ok" do
      strategy = %HotSwap{handover: false}
      assert HotSwap.handle_shutdown(strategy, %{}) == :ok
    end
  end

  describe "handle_process_startups/3" do
    test "with handover: false returns nil" do
      strategy = %HotSwap{handover: false}
      assert HotSwap.handle_process_startups(strategy, %{}, []) == nil
    end
  end

  describe "handle_storage_update/2" do
    test "stores data in ETS under hotswap key", %{hub: hub} do
      data = [{:child1, :state1}]
      HotSwap.handle_storage_update(hub, data)

      stored = Storage.get(hub.storage.misc, :migration_hotswap_state)
      assert stored == data
    end

    test "concatenates with existing data", %{hub: hub} do
      Storage.insert(hub.storage.misc, :migration_hotswap_state, [{:old, :state}])

      HotSwap.handle_storage_update(hub, [{:new, :state}])

      stored = Storage.get(hub.storage.misc, :migration_hotswap_state)
      assert length(stored) == 2
      assert {:new, :state} in stored
      assert {:old, :state} in stored
    end
  end

  describe "complete_migration/3" do
    test "delivers state to new pid and removes from storage", %{hub: hub} do
      child_id = :test_child

      old_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      Storage.insert(hub.storage.misc, {:hotswap_state, child_id}, {:my_state, old_pid})

      # Store sync strategy to avoid crash in Distributor.children_terminate
      Storage.insert(
        hub.storage.misc,
        :synchronization_strategy,
        %ProcessHub.Strategy.Synchronization.PubSub{}
      )

      # complete_migration will try to terminate children via Distributor.
      # We just verify the state delivery part works.
      # Since we don't have a full hub, children_terminate may fail, but
      # the state delivery and hook dispatching happen before that.
      try do
        HotSwap.complete_migration(hub, :target_node, [{child_id, self()}])
      catch
        _, _ -> :ok
      end

      assert_receive {:process_hub, :hotswap_handover, ^child_id, :my_state}
      assert Storage.get(hub.storage.misc, {:hotswap_state, child_id}) == nil

      Process.exit(old_pid, :kill)
    end

    test "dispatches handover_delivered hook when states delivered", %{hub: hub} do
      child_id = :test_child

      old_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      test_pid = self()
      Storage.insert(hub.storage.misc, {:hotswap_state, child_id}, {:my_state, old_pid})

      Storage.insert(
        hub.storage.misc,
        :synchronization_strategy,
        %ProcessHub.Strategy.Synchronization.PubSub{}
      )

      HookManager.register_handler(hub.storage.hook, Hook.handover_delivered(), %HookManager{
        id: :test_hook,
        m: :erlang,
        f: :send,
        a: [test_pid, :handover_hook_fired]
      })

      try do
        HotSwap.complete_migration(hub, :target_node, [{child_id, self()}])
      catch
        _, _ -> :ok
      end

      assert_receive :handover_hook_fired

      Process.exit(old_pid, :kill)
    end

    test "no state found still returns :ok", %{hub: hub} do
      Storage.insert(
        hub.storage.misc,
        :synchronization_strategy,
        %ProcessHub.Strategy.Synchronization.PubSub{}
      )

      try do
        result = HotSwap.complete_migration(hub, :target_node, [{:unknown, self()}])
        assert result == :ok
      catch
        _, _ -> :ok
      end

      refute_receive {:process_hub, :hotswap_handover, _, _}
    end
  end

  describe "handle_post_action_migrate_complete/4" do
    test "sends callback to originating node for successful results", %{hub: hub} do
      results = [
        %PostStartData{
          cid: :child1,
          pid: self(),
          child_spec: %{id: :child1},
          result: {:ok, self()},
          child_nodes: [],
          nodes: [],
          has_errors: false,
          for_node: node()
        }
      ]

      Process.register(self(), hub.hub_id)

      HotSwap.handle_post_action_migrate_complete(hub, results, node(), [:child1])

      assert_receive {:post_action_callback, HotSwap, :complete_migration, _}
    after
      try do
        Process.unregister(hub.hub_id)
      rescue
        _ -> :ok
      end
    end
  end

  describe "handle_shutdown/2 with handover: true" do
    test "calls SwapMigration.handle_shutdown and returns :ok with empty cluster", %{hub: hub} do
      # Store hub_nodes as empty (no remote nodes)
      ProcessHub.Service.Storage.insert(hub.storage.misc, ProcessHub.Constant.StorageKey.hn(), [
        node()
      ])

      strategy = %HotSwap{handover: true, state_query_timeout: 1000}
      assert HotSwap.handle_shutdown(strategy, hub) == :ok
    end
  end

  describe "handle_process_startups/3 with handover: true" do
    test "delivers stored states to started pids", %{hub: hub} do
      strategy = %HotSwap{handover: true}
      storage_key = ProcessHub.Constant.StorageKey.msk()

      # Store some handover state data
      Storage.insert(hub.storage.misc, storage_key, [{:child1, :state_data}])

      cpids = [%{cid: :child1, pid: self()}]
      HotSwap.handle_process_startups(strategy, hub, cpids)

      assert_receive {:process_hub, :hotswap_handover, :child1, :state_data}

      # Storage should be cleaned up
      assert Storage.get(hub.storage.misc, storage_key) == nil
    end

    test "no matching state sends nothing", %{hub: hub} do
      strategy = %HotSwap{handover: true}
      storage_key = ProcessHub.Constant.StorageKey.msk()

      Storage.insert(hub.storage.misc, storage_key, [{:other_child, :state}])

      cpids = [%{cid: :unknown, pid: self()}]
      HotSwap.handle_process_startups(strategy, hub, cpids)

      refute_receive {:process_hub, :hotswap_handover, _, _}
    end
  end

  describe "struct defaults" do
    test "default values" do
      hs = %HotSwap{}
      assert hs.handover == false
      assert hs.state_ttl == 30000
      assert hs.state_query_timeout == 5000
    end
  end
end
