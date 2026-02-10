defmodule Test.Service.SynchronizerTest do
  alias ProcessHub.Service.Synchronizer
  alias ProcessHub.Service.ProcessRegistry

  use ExUnit.Case

  setup do
    Test.Helper.SetupHelper.setup_base(%{}, :synchronizer_test)
  end

  test "local sync data", %{hub: hub} = _context do
    assert Synchronizer.local_sync_data(hub) === []

    ProcessHub.DistributedSupervisor.start_child(
      hub.procs.dist_sup,
      %{
        id: :test1,
        start: {Test.Helper.TestServer, :start_link, [%{name: :test_synchronizer}]}
      }
    )

    ProcessRegistry.insert(hub.hub_id, %{id: :test1}, [{node(), self()}],
      metadata: %{tag: "hello"}
    )

    ProcessRegistry.insert(hub.hub_id, %{id: :test2}, [{:somethingelse, self()}])

    [{child_spec, pid, metadata}] = Synchronizer.local_sync_data(hub)

    assert is_map(child_spec)
    assert is_pid(pid)
    assert is_map(metadata)
    assert metadata.tag === "hello"
  end

  test "append data", %{hub: hub} = _context do
    Synchronizer.append_data(hub, %{node() => [{%{id: :test1}, self(), %{}}]})
    Synchronizer.append_data(hub, %{node() => [{%{id: :test2}, self(), %{}}]})
    Synchronizer.append_data(hub, %{:othernode => [{%{id: :test3}, self(), %{}}]})

    registry = ProcessRegistry.dump(hub.hub_id)

    assert Map.to_list(registry) |> length() === 3

    Enum.each(registry, fn {_child_id, {child_spec, child_nodes, metadata}} ->
      assert is_map(child_spec)
      assert is_list(child_nodes)
      assert is_map(metadata)

      Enum.each(child_nodes, fn {node, pid} ->
        assert is_atom(node)
        assert is_pid(pid)
      end)
    end)
  end

  test "detach data", %{hub: hub} = _context do
    Synchronizer.append_data(hub, %{node() => [{%{id: :test1}, :pid, %{}}]})
    Synchronizer.append_data(hub, %{node() => [{%{id: :test2}, :pid, %{}}]})
    Synchronizer.append_data(hub, %{:othernode => [{%{id: :test3}, :pid, %{}}]})

    registry = ProcessRegistry.dump(hub.hub_id)
    assert Map.to_list(registry) |> length() === 3

    Synchronizer.detach_data(hub, %{:othernode => []})
    Synchronizer.detach_data(hub, %{node() => []})

    registry = ProcessRegistry.dump(hub.hub_id)
    assert Map.to_list(registry) |> length() === 0
  end

  test "broadcast_local_registry with empty registry", %{hub: hub} = _context do
    # With no local data, broadcast should still succeed
    result = Synchronizer.broadcast_local_registry(hub, [:fake_node1, :fake_node2])

    assert result === :ok
  end

  test "trigger_sync uses the configured sync strategy and local data", %{hub: hub} = _context do
    # Insert local registry data that trigger_sync will pick up via local_sync_data
    ProcessRegistry.insert(hub.hub_id, %{id: :sync_trigger1}, [{node(), self()}],
      metadata: %{tag: "sync1"}
    )

    ProcessRegistry.insert(hub.hub_id, %{id: :sync_trigger2}, [{node(), self()}],
      metadata: %{tag: "sync2"}
    )

    # Verify the data is visible to local_sync_data (which trigger_sync uses internally)
    local_data = Synchronizer.local_sync_data(hub)
    assert length(local_data) === 2
    child_ids = Enum.map(local_data, fn {cs, _pid, _meta} -> cs.id end)
    assert :sync_trigger1 in child_ids
    assert :sync_trigger2 in child_ids

    # trigger_sync spawns a task that calls IntervalSyncInit.handle
    # which broadcasts local data via the sync strategy. Should complete without error.
    assert Synchronizer.trigger_sync(hub) === :ok

    # Data should still be intact after sync (sync doesn't mutate local state)
    assert length(Synchronizer.local_sync_data(hub)) === 2
  end

  test "broadcast_local_registry with local data", %{hub: hub} = _context do
    # Insert some local registry data first
    ProcessRegistry.insert(hub.hub_id, %{id: :broadcast_test1}, [{node(), self()}],
      metadata: %{tag: "test1"}
    )

    ProcessRegistry.insert(hub.hub_id, %{id: :broadcast_test2}, [{node(), self()}],
      metadata: %{tag: "test2"}
    )

    # Verify local_sync_data returns the inserted data
    local_data = Synchronizer.local_sync_data(hub)
    assert length(local_data) === 2

    # Broadcast should succeed - actual network send fails silently since nodes don't exist
    result = Synchronizer.broadcast_local_registry(hub, [:fake_node1, :fake_node2])

    assert result === :ok
  end
end
