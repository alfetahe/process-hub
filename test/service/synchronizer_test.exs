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
      hub.managers.distributed_supervisor,
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
end
