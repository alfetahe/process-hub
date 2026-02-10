defmodule Test.Service.StateTest do
  alias ProcessHub.Service.State
  alias ProcessHub.Constant.PriorityLevel

  use ExUnit.Case

  setup do
    Test.Helper.SetupHelper.setup_base(%{}, :state_test)
  end

  test "is partitioned?", %{hub: hub} = _context do
    assert State.is_partitioned?(hub) === false
    State.toggle_quorum_failure(hub)
    assert State.is_partitioned?(hub) === true
    State.toggle_quorum_success(hub)
    assert State.is_partitioned?(hub) === false
  end

  test "is locked?", %{hub: hub} = _context do
    assert State.is_locked?(hub) === false
    :blockade.set_priority(hub.procs.event_queue, PriorityLevel.low())
    assert State.is_locked?(hub) === false
    :blockade.set_priority(hub.procs.event_queue, PriorityLevel.high())
    assert State.is_locked?(hub) === true
  end

  test "lock event handler", %{hub: hub} = _context do
    assert State.is_locked?(hub) === false
    State.lock_event_handler(hub)
    assert State.is_locked?(hub) === true
  end

  test "unlock event handler", %{hub: hub} = _context do
    assert State.is_locked?(hub) === false
    State.lock_event_handler(hub)
    assert State.is_locked?(hub) === true
    State.unlock_event_handler(hub)
    assert State.is_locked?(hub) === false
  end

  test "toggle quorum failure", %{hub: hub} = _context do
    assert State.is_locked?(hub) === false
    assert State.toggle_quorum_failure(hub) === :ok
    assert State.toggle_quorum_failure(hub) === {:error, :already_partitioned}
    assert State.is_locked?(hub) === true
    assert Registry.lookup(hub.procs.system_registry, "dist_sup") === []
  end

  test "toggle quorum success", %{hub: hub} = _context do
    assert State.is_locked?(hub) === false
    assert State.toggle_quorum_failure(hub) === :ok
    assert State.is_locked?(hub) === true
    assert Registry.lookup(hub.procs.system_registry, "dist_sup") === []
    assert State.toggle_quorum_success(hub) === :ok
    assert State.toggle_quorum_success(hub) === {:error, :not_partitioned}
    assert State.is_locked?(hub) === false
    assert Registry.lookup(hub.procs.system_registry, "dist_sup") |> List.first() |> elem(0)
  end

  test "is_partitioned? returns false for multiple dist_sup registrations" do
    reg_name = :"state_test_dup_registry_#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.start_link(keys: :duplicate, name: reg_name)

    {:ok, _} = Registry.register(reg_name, "dist_sup", nil)

    test_pid = self()

    task =
      Task.async(fn ->
        {:ok, _} = Registry.register(reg_name, "dist_sup", nil)
        send(test_pid, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered, 1000

    fake_hub = %{procs: %{system_registry: reg_name}}
    assert State.is_partitioned?(fake_hub) === false

    Task.shutdown(task, :brutal_kill)
  end
end
