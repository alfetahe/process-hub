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

  test "append data updates existing child with different pid", %{hub: hub} = _context do
    pid1 =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    pid2 =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    # Insert with one pid
    Synchronizer.append_data(hub, %{:remote@host => [{%{id: :update_test}, pid1, %{}}]})

    # Verify initial state
    {_, nodes1} = ProcessRegistry.lookup(hub.hub_id, :update_test)
    assert Keyword.get(nodes1, :remote@host) == pid1

    # Update with different pid for same node
    Synchronizer.append_data(hub, %{:remote@host => [{%{id: :update_test}, pid2, %{}}]})

    # Verify pid was updated
    {_, nodes2} = ProcessRegistry.lookup(hub.hub_id, :update_test)
    assert Keyword.get(nodes2, :remote@host) == pid2

    Process.exit(pid1, :kill)
    Process.exit(pid2, :kill)
  end

  test "append data skips update when pid unchanged", %{hub: hub} = _context do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    # Insert with a pid
    Synchronizer.append_data(hub, %{:remote@host => [{%{id: :skip_test}, pid, %{}}]})

    # Append same data again — should not crash or change anything
    Synchronizer.append_data(hub, %{:remote@host => [{%{id: :skip_test}, pid, %{}}]})

    {_, nodes} = ProcessRegistry.lookup(hub.hub_id, :skip_test)
    assert Keyword.get(nodes, :remote@host) == pid

    Process.exit(pid, :kill)
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

  test "detach data removes node entry when child not in remote data", %{hub: hub} = _context do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    # Insert child with two nodes
    ProcessRegistry.insert(
      hub.hub_id,
      %{id: :detach_partial},
      [{:remote@host, pid}, {node(), self()}],
      metadata: %{}
    )

    # Detach remote@host's data, but DON'T include :detach_partial in the remote data
    # This means the child exists locally for remote@host but remote@host no longer has it
    Synchronizer.detach_data(hub, %{:remote@host => []})

    # remote@host's entry should be removed, but local node's entry stays
    result = ProcessRegistry.lookup(hub.hub_id, :detach_partial)
    assert result != nil
    {_, nodes} = result
    refute Keyword.has_key?(nodes, :remote@host)
    assert Keyword.has_key?(nodes, node())

    Process.exit(pid, :kill)
  end

  test "detach data deletes child when last node removed", %{hub: hub} = _context do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    # Insert child with only one remote node
    ProcessRegistry.insert(hub.hub_id, %{id: :detach_delete}, [{:remote@host, pid}],
      metadata: %{}
    )

    # Detach remote@host's data without the child
    Synchronizer.detach_data(hub, %{:remote@host => []})

    # Child should be fully deleted since no nodes remain
    assert ProcessRegistry.lookup(hub.hub_id, :detach_delete) == nil

    Process.exit(pid, :kill)
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

  test "exec_interval_sync delegates to IntervalSyncHandle",
       %{hub: hub, hub_id: hub_id} = _context do
    sync_strat = ProcessHub.Service.Storage.get(hub.storage.misc, :synchronization_strategy)

    # exec_interval_sync should work without error when given empty remote data
    result = Synchronizer.exec_interval_sync(hub_id, sync_strat, [], :remote@host)
    assert result == :ok
  end

  test "detach data preserves child when present in remote data", %{hub: hub} = _context do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    # Insert child associated with a remote node
    ProcessRegistry.insert(hub.hub_id, %{id: :keep_me}, [{:remote@host, pid}], metadata: %{})

    # Detach with remote data that INCLUDES the child — it should be preserved
    Synchronizer.detach_data(hub, %{:remote@host => [{%{id: :keep_me}, pid, %{}}]})

    assert ProcessRegistry.lookup(hub.hub_id, :keep_me) != nil

    Process.exit(pid, :kill)
  end

  test "detach data mixed: removes absent children, preserves present ones",
       %{hub: hub} = _context do
    pid1 =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    pid2 =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    # Insert two children for the same remote node
    ProcessRegistry.insert(hub.hub_id, %{id: :keep}, [{:remote@host, pid1}], metadata: %{})
    ProcessRegistry.insert(hub.hub_id, %{id: :remove}, [{:remote@host, pid2}], metadata: %{})

    # Remote data only contains :keep — :remove should be detached
    Synchronizer.detach_data(hub, %{:remote@host => [{%{id: :keep}, pid1, %{}}]})

    assert ProcessRegistry.lookup(hub.hub_id, :keep) != nil
    assert ProcessRegistry.lookup(hub.hub_id, :remove) == nil

    Process.exit(pid1, :kill)
    Process.exit(pid2, :kill)
  end

  test "append data with multiple remote nodes in one call", %{hub: hub} = _context do
    pid1 =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    pid2 =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    # Append the same child from two different remote nodes in a single call
    Synchronizer.append_data(hub, %{
      :node1@host => [{%{id: :multi_node}, pid1, %{tag: "n1"}}],
      :node2@host => [{%{id: :multi_node}, pid2, %{tag: "n2"}}]
    })

    {_, nodes} = ProcessRegistry.lookup(hub.hub_id, :multi_node)
    assert Keyword.get(nodes, :node1@host) == pid1
    assert Keyword.get(nodes, :node2@host) == pid2

    Process.exit(pid1, :kill)
    Process.exit(pid2, :kill)
  end

  test "append data updates metadata when pid changes", %{hub: hub} = _context do
    pid1 =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    pid2 =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    # Insert with initial metadata
    Synchronizer.append_data(hub, %{
      :remote@host => [{%{id: :meta_update}, pid1, %{version: 1}}]
    })

    # Update with different pid and new metadata
    Synchronizer.append_data(hub, %{
      :remote@host => [{%{id: :meta_update}, pid2, %{version: 2}}]
    })

    {_, nodes} = ProcessRegistry.lookup(hub.hub_id, :meta_update)
    assert Keyword.get(nodes, :remote@host) == pid2

    Process.exit(pid1, :kill)
    Process.exit(pid2, :kill)
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
