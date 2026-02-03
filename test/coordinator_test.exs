defmodule CoordinatorTest do
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
end
