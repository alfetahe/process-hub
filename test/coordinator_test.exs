defmodule CoordinatorTest do
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Coordinator

  use ProcessHub.Constant.Event
  use ExUnit.Case

  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.RequestManager
  alias ProcessHub.Hub

  describe "req_cleanup_interval configuration" do
    test "default value" do
      hub_id = :coord_cleanup_default
      ProcessHub.start_link(%ProcessHub{hub_id: hub_id})

      hub = ProcessHub.Coordinator.get_hub(hub_id)
      interval = Storage.get(hub.storage.misc, StorageKey.rci())

      assert interval === 60000
    end

    test "custom value" do
      hub_id = :coord_cleanup_custom
      custom_interval = 120_000

      ProcessHub.start_link(%ProcessHub{
        hub_id: hub_id,
        req_cleanup_interval: custom_interval
      })

      hub = ProcessHub.Coordinator.get_hub(hub_id)
      interval = Storage.get(hub.storage.misc, StorageKey.rci())

      assert interval === custom_interval
    end
  end

  describe "request cleanup" do
    test "cleanup_expired removes expired operations" do
      now = System.monotonic_time(:millisecond)

      expired_op = %RequestManager{
        transaction_id: make_ref(),
        hub_id: :test_hub,
        handler: nil,
        nodes_data: [],
        expires_at: now - 1000,
        awaiter: nil,
        future: nil
      }

      valid_op = %RequestManager{
        transaction_id: make_ref(),
        hub_id: :test_hub,
        handler: nil,
        nodes_data: [],
        expires_at: now + 60_000,
        awaiter: nil,
        future: nil
      }

      state = %Hub{
        hub_id: :test_hub,
        procs: %{},
        storage: %{},
        pending_operations: %{
          expired_op.transaction_id => expired_op,
          valid_op.transaction_id => valid_op
        }
      }

      cleaned_state = RequestManager.cleanup_expired(state)

      assert map_size(cleaned_state.pending_operations) === 1
      assert Map.has_key?(cleaned_state.pending_operations, valid_op.transaction_id)
      refute Map.has_key?(cleaned_state.pending_operations, expired_op.transaction_id)
    end

    test "cleanup message removes expired operations" do
      hub_id = :coord_cleanup_message

      ProcessHub.start_link(%ProcessHub{hub_id: hub_id})

      # Inject an expired operation directly into coordinator state
      expired_op = %RequestManager{
        transaction_id: make_ref(),
        hub_id: hub_id,
        handler: nil,
        nodes_data: [],
        expires_at: System.monotonic_time(:millisecond) - 1000,
        awaiter: nil,
        future: nil
      }

      # Update coordinator state with the expired operation
      :sys.replace_state(hub_id, fn state ->
        %{
          state
          | pending_operations:
              Map.put(state.pending_operations, expired_op.transaction_id, expired_op)
        }
      end)

      # Verify operation was added
      updated_hub = ProcessHub.Coordinator.get_hub(hub_id)
      assert map_size(updated_hub.pending_operations) === 1

      # Trigger cleanup directly by sending the cleanup message
      send(Process.whereis(hub_id), :cleanup_expired_requests)

      # Allow message to be processed
      _ = ProcessHub.Coordinator.get_hub(hub_id)

      # Verify operation was cleaned up
      final_hub = ProcessHub.Coordinator.get_hub(hub_id)
      assert map_size(final_hub.pending_operations) === 0
    end
  end

  describe "cluster event processing" do
    @hub_id :coord_cluster_test

    setup %{} do
      local_node = node()
      context = Test.Helper.SetupHelper.setup_base(%{}, @hub_id)

      on_exit(fn ->
        ProcessHub.Service.Storage.insert(context.hub.storage.misc, :hub_nodes, [local_node])
      end)

      context
    end

    test "process_hub_join dispatches hooks with correct node data", %{hub: hub} = _context do
      test_pid = self()

      handler = %HookManager{
        id: :cluster_test_hub_join_hook,
        m: __MODULE__,
        f: :send_hook_data,
        a: [test_pid, :hub_join, :_]
      }

      HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_join(), handler)

      # Add multiple new nodes
      Coordinator.process_hub_join(hub, [:new_node1, :new_node2, :new_node3])

      # Verify hook is called with each specific node name
      assert_receive {:hook_called, :hub_join, :new_node1}, 1000
      assert_receive {:hook_called, :hub_join, :new_node2}, 1000
      assert_receive {:hook_called, :hub_join, :new_node3}, 1000

      # Verify no extra hook calls
      refute_receive {:hook_called, :hub_join, _}, 100
    end

    test "process_hub_join filters local node and existing nodes", %{hub: hub} = _context do
      local_node = node()
      test_pid = self()

      handler = %HookManager{
        id: :cluster_test_hub_join_filter,
        m: __MODULE__,
        f: :send_hook_data,
        a: [test_pid, :hub_join_filter, :_]
      }

      HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_join(), handler)

      # Add a node to simulate existing node
      Cluster.add_hub_node(hub.storage.misc, :existing_node)

      # process_hub_join should filter out local node and existing nodes
      # Only :truly_new_node should trigger hook
      result = Coordinator.process_hub_join(hub, [local_node, :existing_node, :truly_new_node])

      assert result.hub_id === hub.hub_id

      # Only the truly new node should trigger hook
      assert_receive {:hook_called, :hub_join_filter, :truly_new_node}, 1000

      # Verify only one hook call (no extra calls for filtered nodes)
      refute_receive {:hook_called, :hub_join_filter, _}, 100
    end

    test "process_node_down_batch dispatches hook for single node", %{hub: hub} = _context do
      test_pid = self()

      handler = %HookManager{
        id: :cluster_test_node_down_hook,
        m: __MODULE__,
        f: :send_hook_data,
        a: [test_pid, :node_down, :_]
      }

      HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_leave(), handler)

      # Add the node first so it can be "removed"
      Cluster.add_hub_node(hub.storage.misc, :node_to_remove)

      # process_node_down_batch should dispatch the hook with the node name
      result = Coordinator.process_node_down_batch(hub, [:node_to_remove])

      assert result.hub_id === hub.hub_id

      # Verify the exact node passed to hook matches expected
      assert_receive {:hook_called, :node_down, :node_to_remove}, 1000
    end

    test "process_node_down_batch ignores nodes not in hub", %{hub: hub} = _context do
      test_pid = self()

      handler = %HookManager{
        id: :cluster_test_node_down_ignore,
        m: __MODULE__,
        f: :send_hook_data,
        a: [test_pid, :node_down_ignore, :_]
      }

      HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_leave(), handler)

      # Try to remove a node that doesn't exist in the hub
      result = Coordinator.process_node_down_batch(hub, [:non_existent_node])

      assert result.hub_id === hub.hub_id
      refute_receive {:hook_called, :node_down_ignore, _}, 100
    end

    test "process_node_down_batch dispatches hooks with correct node data",
         %{hub: hub} = _context do
      test_pid = self()

      handler = %HookManager{
        id: :cluster_test_batch_down_hook,
        m: __MODULE__,
        f: :send_hook_data,
        a: [test_pid, :batch_down, :_]
      }

      HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_leave(), handler)

      # Add multiple nodes
      Cluster.add_hub_node(hub.storage.misc, :batch_node1)
      Cluster.add_hub_node(hub.storage.misc, :batch_node2)
      Cluster.add_hub_node(hub.storage.misc, :batch_node3)

      # Process batch with some valid and one invalid node
      result = Coordinator.process_node_down_batch(hub, [:batch_node1, :batch_node2, :non_existent])

      assert result.hub_id === hub.hub_id

      # Verify each valid node receives its own hook call with correct data
      assert_receive {:hook_called, :batch_down, :batch_node1}, 1000
      assert_receive {:hook_called, :batch_down, :batch_node2}, 1000

      # Invalid nodes don't trigger hooks
      refute_receive {:hook_called, :batch_down, :non_existent}, 100
    end

    test "process_node_down_batch handles all nodes in batch", %{hub: hub} = _context do
      test_pid = self()

      handler = %HookManager{
        id: :cluster_test_batch_all,
        m: __MODULE__,
        f: :send_hook_data,
        a: [test_pid, :batch_all, :_]
      }

      HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_leave(), handler)

      # Add multiple nodes
      Cluster.add_hub_node(hub.storage.misc, :all_node1)
      Cluster.add_hub_node(hub.storage.misc, :all_node2)
      Cluster.add_hub_node(hub.storage.misc, :all_node3)
      Cluster.add_hub_node(hub.storage.misc, :all_node4)

      # Process batch with all valid nodes
      result =
        Coordinator.process_node_down_batch(hub, [:all_node1, :all_node2, :all_node3, :all_node4])

      assert result.hub_id === hub.hub_id

      # Verify all hooks dispatched with correct node names
      assert_receive {:hook_called, :batch_all, :all_node1}, 1000
      assert_receive {:hook_called, :batch_all, :all_node2}, 1000
      assert_receive {:hook_called, :batch_all, :all_node3}, 1000
      assert_receive {:hook_called, :batch_all, :all_node4}, 1000

      # Verify no extra hook calls
      refute_receive {:hook_called, :batch_all, _}, 100
    end

    test "process_node_down_batch ignores empty valid nodes list", %{hub: hub} = _context do
      test_pid = self()

      handler = %HookManager{
        id: :cluster_test_batch_empty,
        m: __MODULE__,
        f: :send_hook_data,
        a: [test_pid, :batch_empty, :_]
      }

      HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_leave(), handler)

      # Try to remove nodes that don't exist
      result = Coordinator.process_node_down_batch(hub, [:non_existent1, :non_existent2])

      assert result.hub_id === hub.hub_id
      refute_receive {:hook_called, :batch_empty, _}, 100
    end
  end

  # Helper function to send hook data with a tag
  def send_hook_data(pid, tag, node_data) do
    send(pid, {:hook_called, tag, node_data})
  end
end
