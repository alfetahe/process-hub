defmodule Test.Strategy.Synchronization.PubSubTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Synchronization.PubSub
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey

  setup_all do
    hub_id = :"pubsub_test_#{:erlang.unique_integer([:positive])}"
    Test.Helper.SetupHelper.setup_base(%{}, hub_id)
  end

  describe "init/2" do
    test "returns strategy unchanged", %{hub: hub} do
      strategy = %PubSub{sync_interval: 5000}
      result = SynchronizationStrategy.init(strategy, hub)
      assert result == strategy
    end
  end

  describe "handle_synchronization/4" do
    test "processes remote data and updates registry", %{hub: hub} do
      strategy = %PubSub{}
      unique = :erlang.unique_integer([:positive])

      child_spec = %{
        id: :"pubsub_sync_child_#{unique}",
        start: {Agent, :start_link, [fn -> nil end]}
      }

      remote_data = [{child_spec, self(), %{}}]

      result =
        SynchronizationStrategy.handle_synchronization(strategy, hub, remote_data, :remote@host)

      assert result == :ok

      # Verify child was inserted into the registry
      lookup = ProcessHub.Service.ProcessRegistry.lookup(hub.hub_id, child_spec.id)
      assert lookup != nil
    end
  end

  describe "handle_node_join_data/4" do
    test "with no previous timestamp stores data and timestamp", %{hub: hub} do
      strategy = %PubSub{}
      remote_node = :"new_node_#{:erlang.unique_integer([:positive])}@host"
      timestamp = System.system_time(:microsecond)
      remote_data = {[], timestamp}

      result =
        SynchronizationStrategy.handle_node_join_data(strategy, hub, remote_data, remote_node)

      assert result == :ok

      timestamps = Storage.get(hub.storage.misc, StorageKey.gct())
      assert timestamps != nil
      assert Map.get(timestamps, remote_node) == timestamp
    end

    test "with newer timestamp updates data and timestamp", %{hub: hub} do
      strategy = %PubSub{}
      remote_node = :"newer_node_#{:erlang.unique_integer([:positive])}@host"
      old_timestamp = 1000
      new_timestamp = 2000

      # Store old timestamp
      old_timestamps = Storage.get(hub.storage.misc, StorageKey.gct()) || %{}

      Storage.insert(
        hub.storage.misc,
        StorageKey.gct(),
        Map.put(old_timestamps, remote_node, old_timestamp)
      )

      remote_data = {[], new_timestamp}
      SynchronizationStrategy.handle_node_join_data(strategy, hub, remote_data, remote_node)

      timestamps = Storage.get(hub.storage.misc, StorageKey.gct())
      assert Map.get(timestamps, remote_node) == new_timestamp
    end

    test "with older timestamp skips update", %{hub: hub} do
      strategy = %PubSub{}
      remote_node = :"old_node_#{:erlang.unique_integer([:positive])}@host"
      stored_timestamp = 5000

      old_timestamps = Storage.get(hub.storage.misc, StorageKey.gct()) || %{}

      Storage.insert(
        hub.storage.misc,
        StorageKey.gct(),
        Map.put(old_timestamps, remote_node, stored_timestamp)
      )

      old_timestamp = 3000
      remote_data = {[], old_timestamp}
      SynchronizationStrategy.handle_node_join_data(strategy, hub, remote_data, remote_node)

      timestamps = Storage.get(hub.storage.misc, StorageKey.gct())
      assert Map.get(timestamps, remote_node) == stored_timestamp
    end
  end

  describe "broadcast_local_data/4" do
    test "dispatches sync event with local data", %{hub: hub} do
      strategy = %PubSub{}
      unique = :erlang.unique_integer([:positive])

      # Insert registry data so broadcast has something to work with
      child_id = :"bcast_#{unique}"
      ProcessHub.Service.ProcessRegistry.insert(hub.hub_id, %{id: child_id}, [{node(), self()}])

      local_data = ProcessHub.Service.Synchronizer.local_sync_data(hub)
      result = SynchronizationStrategy.broadcast_local_data(strategy, hub, local_data, [node()])
      assert result == :ok

      # Verify registry data is still intact after broadcast
      assert ProcessHub.Service.ProcessRegistry.lookup(hub.hub_id, child_id) != nil
    end
  end

  describe "remote_sync_cast/5" do
    test "casts handle_work to worker queue", %{hub: hub} do
      # Use the hub's actual worker_queue which can handle {:handle_work, fn}
      # We just verify it doesn't crash with empty sync_data
      PubSub.remote_sync_cast(hub.procs.worker_queue, hub.hub_id, %PubSub{}, [], node())

      # Verify no crash by checking the worker is still alive
      assert GenServer.whereis(hub.procs.worker_queue) != nil
    end
  end

  describe "struct defaults" do
    test "default sync_interval" do
      strategy = %PubSub{}
      assert strategy.sync_interval == 30000
    end
  end
end
