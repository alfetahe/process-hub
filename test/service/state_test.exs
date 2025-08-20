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
    :blockade.set_priority(hub.managers.event_queue, PriorityLevel.unlocked())
    assert State.is_locked?(hub) === false
    :blockade.set_priority(hub.managers.event_queue, PriorityLevel.locked())
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
    assert Registry.lookup(hub.managers.system_registry, "dist_sup") === []
  end

  test "toggle quorum success", %{hub: hub} = _context do
    assert State.is_locked?(hub) === false
    assert State.toggle_quorum_failure(hub) === :ok
    assert State.is_locked?(hub) === true
    assert Registry.lookup(hub.managers.system_registry, "dist_sup") === []
    assert State.toggle_quorum_success(hub) === :ok
    assert State.toggle_quorum_success(hub) === {:error, :not_partitioned}
    assert State.is_locked?(hub) === false
    assert Registry.lookup(hub.managers.system_registry, "dist_sup") |> List.first() |> elem(0)
  end
end
