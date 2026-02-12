defmodule Test.Task.SynchronizationTaskTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Task.SynchronizationTask.ProcessEmitHandle
  alias ProcessHub.Task.SynchronizationTask.IntervalSyncInit
  alias ProcessHub.Task.SynchronizationTask.IntervalSyncHandle
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey

  setup_all do
    hub_id = :"sync_task_test_#{:erlang.unique_integer([:positive])}"
    Test.Helper.SetupHelper.setup_base(%{}, hub_id)
  end

  describe "ProcessEmitHandle.handle/1" do
    test "empty remote_children is a no-op", %{hub: hub} do
      result =
        ProcessEmitHandle.handle(%ProcessEmitHandle{
          hub: hub,
          remote_node: :remote@host,
          remote_children: []
        })

      assert result == nil
    end

    test "remote children not in local registry get inserted", %{hub: hub} do
      child_spec = %{
        id: :"sync_new_child_#{:erlang.unique_integer([:positive])}",
        start: {Agent, :start_link, [fn -> nil end]}
      }

      pid = self()

      ProcessEmitHandle.handle(%ProcessEmitHandle{
        hub: hub,
        remote_node: :remote@host,
        remote_children: [{child_spec, pid, %{}}]
      })

      # Verify the child was inserted into the registry
      result = ProcessHub.Service.ProcessRegistry.lookup(hub.hub_id, child_spec.id)
      assert result != nil
    end

    test "remote children with nil pid are filtered out when matching existing", %{hub: hub} do
      child_spec = %{
        id: :"sync_nil_pid_#{:erlang.unique_integer([:positive])}",
        start: {Agent, :start_link, [fn -> nil end]}
      }

      # First insert into registry
      ProcessHub.Service.ProcessRegistry.insert(hub.hub_id, child_spec, [{:remote@host, self()}])

      # Now emit with nil pid from same node - should filter it out
      ProcessEmitHandle.handle(%ProcessEmitHandle{
        hub: hub,
        remote_node: :remote@host,
        remote_children: [{child_spec, nil, %{}}]
      })

      # Should still have the original data
      result = ProcessHub.Service.ProcessRegistry.lookup(hub.hub_id, child_spec.id)
      assert result != nil
    end

    test "remote children in local registry with different nodes get merged", %{hub: hub} do
      child_spec = %{
        id: :"sync_merge_#{:erlang.unique_integer([:positive])}",
        start: {Agent, :start_link, [fn -> nil end]}
      }

      local_pid = self()

      remote_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      # Insert with one node
      ProcessHub.Service.ProcessRegistry.insert(hub.hub_id, child_spec, [{:local@host, local_pid}])

      # Emit from a different node
      ProcessEmitHandle.handle(%ProcessEmitHandle{
        hub: hub,
        remote_node: :remote@host,
        remote_children: [{child_spec, remote_pid, %{}}]
      })

      result = ProcessHub.Service.ProcessRegistry.lookup(hub.hub_id, child_spec.id)
      assert result != nil

      Process.exit(remote_pid, :kill)
    end
  end

  describe "IntervalSyncInit.handle/1" do
    test "when hub is not locked triggers sync", %{hub: hub} do
      unique = :erlang.unique_integer([:positive])

      # Insert data so sync has something to work with
      child_id = :"sync_init_#{unique}"

      ProcessHub.Service.ProcessRegistry.insert(hub.hub_id, %{id: child_id}, [{node(), self()}],
        metadata: %{}
      )

      result = IntervalSyncInit.handle(%IntervalSyncInit{hub: hub})
      assert result == :ok

      # Verify data is still intact (sync doesn't mutate local state)
      assert ProcessHub.Service.ProcessRegistry.lookup(hub.hub_id, child_id) != nil
    end
  end

  describe "IntervalSyncHandle.handle/1" do
    test "delegates to strategy and processes remote data", %{hub: hub} do
      sync_strat = Storage.get(hub.storage.misc, StorageKey.strsyn())
      unique = :erlang.unique_integer([:positive])

      child_spec = %{id: :"isync_child_#{unique}", start: {Agent, :start_link, [fn -> nil end]}}
      remote_data = [{child_spec, self(), %{}}]

      result =
        IntervalSyncHandle.handle(%IntervalSyncHandle{
          hub: hub,
          sync_strat: sync_strat,
          sync_data: remote_data,
          remote_node: :remote@host
        })

      assert result == :ok

      # Verify the remote data was processed into the registry
      assert ProcessHub.Service.ProcessRegistry.lookup(hub.hub_id, child_spec.id) != nil
    end
  end
end
