defmodule Test.Strategy.Migration.ColdSwapTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Migration.ColdSwap
  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Request.Handler.StartChildrenRequest.PostStartData

  setup do
    hub_id = :"test_cs_#{:erlang.unique_integer([:positive])}"
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
      strategy = %ColdSwap{handover: false}
      result = MigrationStrategy.init(strategy, hub)
      assert result == strategy

      # Verify NO hooks were registered
      assert HookManager.registered_handlers(hub.storage.hook, Hook.coordinator_shutdown()) == []
      assert HookManager.registered_handlers(hub.storage.hook, Hook.process_startups()) == []
    end

    test "with handover: true registers hook handlers", %{hub: hub} do
      strategy = %ColdSwap{handover: true}
      result = MigrationStrategy.init(strategy, hub)
      assert result == strategy

      shutdown_handlers =
        HookManager.registered_handlers(hub.storage.hook, Hook.coordinator_shutdown())

      startups_handlers =
        HookManager.registered_handlers(hub.storage.hook, Hook.process_startups())

      assert length(shutdown_handlers) == 1
      assert hd(shutdown_handlers).id == :mcs_shutdown

      assert length(startups_handlers) == 1
      assert hd(startups_handlers).id == :mcs_process_startups
    end
  end

  describe "handle_shutdown/2" do
    test "with handover: false returns :ok" do
      strategy = %ColdSwap{handover: false}
      assert ColdSwap.handle_shutdown(strategy, %{}) == :ok
    end
  end

  describe "handle_process_startups/3" do
    test "with handover: false returns nil" do
      strategy = %ColdSwap{handover: false}
      assert ColdSwap.handle_process_startups(strategy, %{}, []) == nil
    end
  end

  describe "handle_storage_update/2" do
    test "stores data in ETS under coldswap key", %{hub: hub} do
      data = [{:child1, :state1}]
      ColdSwap.handle_storage_update(hub, data)

      stored = Storage.get(hub.storage.misc, :migration_coldswap_state)
      assert stored == data
    end

    test "concatenates with existing data", %{hub: hub} do
      Storage.insert(hub.storage.misc, :migration_coldswap_state, [{:old, :state}])

      ColdSwap.handle_storage_update(hub, [{:new, :state}])

      stored = Storage.get(hub.storage.misc, :migration_coldswap_state)
      assert length(stored) == 2
      assert {:new, :state} in stored
      assert {:old, :state} in stored
    end
  end

  describe "deliver_handover_states/3" do
    test "delivers state to pid and removes from storage", %{hub: hub} do
      child_id = :test_child
      Storage.insert(hub.storage.misc, {:coldswap_state, child_id}, :my_state)

      ColdSwap.deliver_handover_states(hub, :target_node, [{child_id, self()}])

      assert_receive {:process_hub, :coldswap_handover, ^child_id, :my_state}
      assert Storage.get(hub.storage.misc, {:coldswap_state, child_id}) == nil
    end

    test "dispatches handover_delivered hook when states delivered", %{hub: hub} do
      child_id = :test_child
      test_pid = self()
      Storage.insert(hub.storage.misc, {:coldswap_state, child_id}, :my_state)

      HookManager.register_handler(hub.storage.hook, Hook.handover_delivered(), %HookManager{
        id: :test_hook,
        m: :erlang,
        f: :send,
        a: [test_pid, :handover_hook_fired]
      })

      ColdSwap.deliver_handover_states(hub, :target_node, [{child_id, self()}])

      assert_receive :handover_hook_fired
    end

    test "no state found returns :ok without hook", %{hub: hub} do
      result = ColdSwap.deliver_handover_states(hub, :target_node, [{:unknown, self()}])
      assert result == :ok
      refute_receive {:process_hub, :coldswap_handover, _, _}
    end

    test "mixed: some found, some not", %{hub: hub} do
      Storage.insert(hub.storage.misc, {:coldswap_state, :found}, :state1)

      ColdSwap.deliver_handover_states(hub, :target_node, [
        {:found, self()},
        {:not_found, self()}
      ])

      assert_receive {:process_hub, :coldswap_handover, :found, :state1}
      refute_receive {:process_hub, :coldswap_handover, :not_found, _}
    end
  end

  describe "handle_post_action_state_fetch/4" do
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

      # Register ourselves as the hub_id process name
      Process.register(self(), hub.hub_id)

      ColdSwap.handle_post_action_state_fetch(hub, results, node(), [:child1])

      assert_receive {:post_action_callback, ColdSwap, :deliver_handover_states, _}
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

      strategy = %ColdSwap{handover: true, state_query_timeout: 1000}
      assert ColdSwap.handle_shutdown(strategy, hub) == :ok
    end
  end

  describe "handle_process_startups/3 with handover: true" do
    test "delivers stored states to started pids", %{hub: hub} do
      strategy = %ColdSwap{handover: true}
      storage_key = ProcessHub.Constant.StorageKey.mcsk()

      # Store some handover state data
      Storage.insert(hub.storage.misc, storage_key, [{:child1, :state_data}])

      cpids = [%{cid: :child1, pid: self()}]
      ColdSwap.handle_process_startups(strategy, hub, cpids)

      assert_receive {:process_hub, :coldswap_handover, :child1, :state_data}

      # Storage should be cleaned up
      assert Storage.get(hub.storage.misc, storage_key) == nil
    end

    test "no matching state sends nothing", %{hub: hub} do
      strategy = %ColdSwap{handover: true}
      storage_key = ProcessHub.Constant.StorageKey.mcsk()

      Storage.insert(hub.storage.misc, storage_key, [{:other_child, :state}])

      cpids = [%{cid: :unknown, pid: self()}]
      ColdSwap.handle_process_startups(strategy, hub, cpids)

      refute_receive {:process_hub, :coldswap_handover, _, _}
    end
  end

  describe "struct defaults" do
    test "default values" do
      cs = %ColdSwap{}
      assert cs.handover == false
      assert cs.state_ttl == 30000
      assert cs.state_query_timeout == 5000
    end
  end
end
