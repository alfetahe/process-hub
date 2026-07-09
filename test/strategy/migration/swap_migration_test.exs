defmodule Test.Strategy.Migration.SwapMigrationTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Migration.SwapMigration
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Request.Handler.StartChildrenRequest.PostStartData

  describe "group_children_by_node/1" do
    test "groups children by target node" do
      cs1 = %{id: :child1}
      cs2 = %{id: :child2}
      cs3 = %{id: :child3}

      forward_to_list = [
        {cs1, %{}, [:node1@host]},
        {cs2, %{}, [:node1@host]},
        {cs3, %{}, [:node2@host]}
      ]

      result = SwapMigration.group_children_by_node(forward_to_list)

      assert length(result[:node1@host]) == 2
      assert length(result[:node2@host]) == 1
    end

    test "handles child with multiple target nodes" do
      cs1 = %{id: :child1}

      forward_to_list = [
        {cs1, %{meta: true}, [:node1@host, :node2@host]}
      ]

      result = SwapMigration.group_children_by_node(forward_to_list)

      assert length(result[:node1@host]) == 1
      assert length(result[:node2@host]) == 1
    end

    test "returns empty map for empty input" do
      assert SwapMigration.group_children_by_node([]) == %{}
    end

    test "preserves metadata" do
      cs1 = %{id: :child1}
      meta = %{custom: "data"}

      result = SwapMigration.group_children_by_node([{cs1, meta, [:node1@host]}])

      [{stored_cs, stored_meta}] = result[:node1@host]
      assert stored_cs == cs1
      assert stored_meta == meta
    end
  end

  describe "find_new_nodes/2" do
    test "returns nodes in new but not in old" do
      old = [:a@host, :b@host]
      new = [:b@host, :c@host, :d@host]

      result = SwapMigration.find_new_nodes(old, new)
      assert :c@host in result
      assert :d@host in result
      refute :b@host in result
    end

    test "returns empty when no new nodes" do
      old = [:a@host, :b@host]
      new = [:a@host, :b@host]

      assert SwapMigration.find_new_nodes(old, new) == []
    end

    test "returns all when old is empty" do
      assert SwapMigration.find_new_nodes([], [:a@host, :b@host]) == [:a@host, :b@host]
    end
  end

  describe "find_existing_nodes/2" do
    test "returns nodes in both lists" do
      old = [:a@host, :b@host, :c@host]
      new = [:b@host, :c@host, :d@host]

      result = SwapMigration.find_existing_nodes(old, new)
      assert :b@host in result
      assert :c@host in result
      refute :a@host in result
      refute :d@host in result
    end

    test "returns empty when no overlap" do
      assert SwapMigration.find_existing_nodes([:a@host], [:b@host]) == []
    end

    test "returns empty when old is empty" do
      assert SwapMigration.find_existing_nodes([], [:a@host]) == []
    end
  end

  describe "eligible_for_sending?/3" do
    test "returns true when registry_nodes is empty (first-time assignment)" do
      assert SwapMigration.eligible_for_sending?([], [:n1@host], node())
    end

    test "returns true when calculated_nodes has only one node" do
      assert SwapMigration.eligible_for_sending?([:old@host], [:n1@host], :old@host)
    end

    test "returns true when local node is first among existing nodes in calculated list" do
      local = node()
      registry_nodes = [local, :n2@host]
      calculated_nodes = [local, :n3@host]

      assert SwapMigration.eligible_for_sending?(registry_nodes, calculated_nodes, local)
    end

    test "returns false when local node is not first existing node" do
      local = node()
      # :a@host sorts before most node names
      registry_nodes = [:a@host, local]
      calculated_nodes = [:a@host, :new@host]

      refute SwapMigration.eligible_for_sending?(registry_nodes, calculated_nodes, local)
    end

    test "returns true when no overlap and local is first sorted old node" do
      # No existing nodes in calculated list, so first sorted registry node takes responsibility
      local = :aaa@host
      registry_nodes = [local, :zzz@host]
      calculated_nodes = [:completely_new@host, :other_new@host]

      assert SwapMigration.eligible_for_sending?(registry_nodes, calculated_nodes, local)
    end

    test "returns false when no overlap and local is not first sorted old node" do
      local = :zzz@host
      registry_nodes = [:aaa@host, local]
      # Need more than 1 calculated node to avoid the "single node" shortcut
      calculated_nodes = [:completely_new@host, :other_new@host]

      refute SwapMigration.eligible_for_sending?(registry_nodes, calculated_nodes, local)
    end
  end

  describe "handle_storage_update/3" do
    setup do
      hub_id = :"test_sm_#{:erlang.unique_integer([:positive])}"
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

    test "no existing data stores new data with TTL", %{hub: hub} do
      data = [{:child1, :state1}]
      SwapMigration.handle_storage_update(hub, data, :test_key)

      stored = Storage.get(hub.storage.misc, :test_key)
      assert stored == data
    end

    test "existing data concatenates and stores", %{hub: hub} do
      Storage.insert(hub.storage.misc, :test_key, [{:old, :data}])

      SwapMigration.handle_storage_update(hub, [{:new, :data}], :test_key)

      stored = Storage.get(hub.storage.misc, :test_key)
      assert length(stored) == 2
      assert {:new, :data} in stored
      assert {:old, :data} in stored
    end
  end

  describe "dispatch_migration_hook/3" do
    setup do
      hub_id = :"test_sm_hook_#{:erlang.unique_integer([:positive])}"
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

    test "empty list returns :ok", %{hub: hub} do
      assert SwapMigration.dispatch_migration_hook(hub, [], [:node1]) == :ok
    end

    test "non-empty list dispatches hook", %{hub: hub} do
      test_pid = self()

      HookManager.register_handler(
        hub.storage.hook,
        Hook.migration_completed(),
        %HookManager{
          id: :test_migration_hook,
          m: :erlang,
          f: :send,
          a: [test_pid, :migration_hook_fired]
        }
      )

      SwapMigration.dispatch_migration_hook(hub, [%{id: :child1}], [:node1])

      assert_receive :migration_hook_fired
    end
  end

  describe "send_start_requests/2" do
    test "empty list returns :ok" do
      hub = %ProcessHub.Hub{hub_id: :dummy}
      assert SwapMigration.send_start_requests(hub, []) == :ok
    end
  end

  describe "notify_originating_node/6" do
    setup do
      hub_id = :"test_sm_notify_#{:erlang.unique_integer([:positive])}"
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

    test "filters successful results and sends callback", %{hub: hub} do
      Process.register(self(), hub.hub_id)

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
        },
        %PostStartData{
          cid: :child2,
          pid: self(),
          child_spec: %{id: :child2},
          result: {:error, :failed},
          child_nodes: [],
          nodes: [],
          has_errors: true,
          for_node: node()
        }
      ]

      SwapMigration.notify_originating_node(
        hub,
        results,
        node(),
        [:child1, :child2],
        SomeModule,
        :some_fun
      )

      assert_receive {:post_action_callback, SomeModule, :some_fun, [_target_node, cid_pids]}
      # Only child1 should be in the list (successful result)
      assert length(cid_pids) == 1
      assert {:child1, _} = hd(cid_pids)
    after
      try do
        Process.unregister(hub.hub_id)
      rescue
        _ -> :ok
      end
    end

    test "returns :ok when no successful results", %{hub: hub} do
      results = [
        %PostStartData{
          cid: :child1,
          pid: self(),
          child_spec: %{id: :child1},
          result: {:error, :failed},
          child_nodes: [],
          nodes: [],
          has_errors: true,
          for_node: node()
        }
      ]

      result =
        SwapMigration.notify_originating_node(
          hub,
          results,
          node(),
          [:child1],
          SomeModule,
          :some_fun
        )

      assert result == :ok
      refute_receive {:post_action_callback, _, _, _}
    end
  end

  describe "handle_process_startups/4" do
    setup do
      hub_id = :"test_sm_ps_#{:erlang.unique_integer([:positive])}"
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

    test "delivers states from ETS to started pids", %{hub: hub} do
      storage_key = :test_startup_states
      Storage.insert(hub.storage.misc, storage_key, [{:child1, :state1}])

      cpids = [%{cid: :child1, pid: self()}]
      SwapMigration.handle_process_startups(hub, cpids, storage_key, :test_handover)

      assert_receive {:process_hub, :test_handover, :child1, :state1}

      # Storage should be cleaned up
      assert Storage.get(hub.storage.misc, storage_key) == nil
    end

    test "no matching state does not send message", %{hub: hub} do
      storage_key = :test_startup_states_2
      Storage.insert(hub.storage.misc, storage_key, [{:other_child, :state}])

      cpids = [%{cid: :unknown_child, pid: self()}]
      SwapMigration.handle_process_startups(hub, cpids, storage_key, :test_handover)

      refute_receive {:process_hub, :test_handover, _, _}
    end

    test "empty state data does nothing", %{hub: hub} do
      storage_key = :test_startup_states_3
      cpids = [%{cid: :child1, pid: self()}]
      SwapMigration.handle_process_startups(hub, cpids, storage_key, :test_handover)

      refute_receive {:process_hub, :test_handover, _, _}
    end
  end

  describe "collect_states/4" do
    test "returns accumulated states immediately when remaining is empty" do
      result = SwapMigration.collect_states([], 1000, [{:prev, :state}], :coldswap_state)
      assert result == [{:prev, :state}]
    end

    test "collects states from messages" do
      # Send messages that will be picked up
      send(self(), {:process_hub, :coldswap_state, :child1, %{key: "val1"}})
      send(self(), {:process_hub, :coldswap_state, :child2, %{key: "val2"}})

      result = SwapMigration.collect_states([:child1, :child2], 1000, [], :coldswap_state)

      assert length(result) == 2
      cids = Enum.map(result, &elem(&1, 0))
      assert :child1 in cids
      assert :child2 in cids
    end

    test "times out when messages don't arrive" do
      result = SwapMigration.collect_states([:child1], 50, [], :coldswap_state)
      assert result == []
    end

    test "returns partial results on timeout" do
      send(self(), {:process_hub, :hotswap_state, :child1, :state1})

      result = SwapMigration.collect_states([:child1, :child2], 50, [], :hotswap_state)

      assert length(result) == 1
      assert {:child1, :state1} in result
    end
  end

  describe "handle_shutdown/6" do
    setup do
      hub_id = :"test_sm_shutdown_#{:erlang.unique_integer([:positive])}"
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

    test "returns :ok with no remote nodes in cluster", %{hub: hub} do
      # Only local node in the cluster, so length(Cluster.nodes) == 0
      Storage.insert(hub.storage.misc, ProcessHub.Constant.StorageKey.hn(), [node()])

      result =
        SwapMigration.handle_shutdown(
          hub,
          1000,
          :query_cold_handover_state,
          :coldswap_state,
          ProcessHub.Strategy.Migration.ColdSwap,
          "ColdSwap"
        )

      assert result == :ok
    end
  end
end
