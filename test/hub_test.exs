defmodule Test.HubTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Coordinator.State
  alias ProcessHub.Hub

  describe "put/1, get/1 and delete/1" do
    test "store a hub by its id until it is deleted" do
      hub = %Hub{hub_id: :hub_test_stored}

      assert Hub.get(:hub_test_stored) === nil
      assert Hub.put(hub) === :ok
      assert Hub.get(:hub_test_stored) === hub
      assert Hub.delete(:hub_test_stored) === :ok
      assert Hub.get(:hub_test_stored) === nil
    end

    test "a running hub is readable while its coordinator is suspended" do
      hub_id = Test.Helper.SetupHelper.unique_id(:hub_test_running)
      {^hub_id, _pid} = Test.Helper.SetupHelper.start_hub!(hub_id: hub_id)

      :sys.suspend(hub_id)
      on_exit(fn -> :sys.resume(hub_id) end)

      assert %Hub{hub_id: ^hub_id, procs: %{}, storage: %{}, recovery_config: %{}} =
               Hub.get(hub_id)
    end

    test "a stopped hub is no longer readable" do
      hub_id = Test.Helper.SetupHelper.unique_id(:hub_test_stopped)
      {:ok, _pid} = ProcessHub.start_link(%ProcessHub{hub_id: hub_id})

      assert ProcessHub.stop(hub_id) === :ok
      assert Hub.get(hub_id) === nil
    end
  end

  describe "State" do
    test "default_batch_state/0 returns an empty batch" do
      assert State.default_batch_state() == %{nodes: [], timer_ref: nil, started_at: nil}
    end

    test "has expected default values" do
      state = %State{}
      assert state.hub == nil
      assert state.pending_operations == %{}
      assert state.pending_work_count == 0

      for event <- [:nodedown, :cluster_leave, :cluster_join] do
        assert state.event_batches[event] == State.default_batch_state()
      end
    end
  end
end
