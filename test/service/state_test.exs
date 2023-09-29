defmodule Test.Service.StateTest do
  alias ProcessHub.Service.State
  alias ProcessHub.Utility.Name
  alias ProcessHub.Constant.PriorityLevel

  use ExUnit.Case

  setup do
    Test.Helper.SetupHelper.setup_base(%{}, :state_test)
  end

  test "is partitioned?", %{hub_id: hub_id} = _context do
    assert State.is_partitioned?(hub_id) === false
    State.toggle_quorum_failure(hub_id)
    assert State.is_partitioned?(hub_id) === true
    State.toggle_quorum_success(hub_id)
    assert State.is_partitioned?(hub_id) === false
  end

  test "is locked?", %{hub_id: hub_id} = _context do
    assert State.is_locked?(hub_id) === false
    :blockade.set_priority(Name.local_event_queue(hub_id), PriorityLevel.unlocked())
    assert State.is_locked?(hub_id) === false
    :blockade.set_priority(Name.local_event_queue(hub_id), PriorityLevel.locked())
    assert State.is_locked?(hub_id) === true
  end

  test "lock local event handler", %{hub_id: hub_id} = _context do
    assert State.is_locked?(hub_id) === false
    State.lock_local_event_handler(hub_id)
    assert State.is_locked?(hub_id) === true
  end

  test "unlock local event handler", %{hub_id: hub_id} = _context do
    assert State.is_locked?(hub_id) === false
    State.lock_local_event_handler(hub_id)
    assert State.is_locked?(hub_id) === true
    State.unlock_local_event_handler(hub_id)
    assert State.is_locked?(hub_id) === false
  end

  test "toggle quorum failure", %{hub_id: hub_id} = _context do
    assert State.is_locked?(hub_id) === false
    assert State.toggle_quorum_failure(hub_id) === :ok
    assert State.toggle_quorum_failure(hub_id) === {:error, :already_partitioned}
    assert State.is_locked?(hub_id) === true
    assert Process.whereis(Name.distributed_supervisor(hub_id)) === nil
  end

  test "toggle quorum success", %{hub_id: hub_id} = _context do
    assert State.is_locked?(hub_id) === false
    assert State.toggle_quorum_failure(hub_id) === :ok
    assert State.is_locked?(hub_id) === true
    assert Process.whereis(Name.distributed_supervisor(hub_id)) === nil
    assert State.toggle_quorum_success(hub_id) === :ok
    assert State.toggle_quorum_success(hub_id) === {:error, :not_partitioned}
    assert State.is_locked?(hub_id) === false
    assert is_pid(Process.whereis(Name.distributed_supervisor(hub_id)))
  end
end
