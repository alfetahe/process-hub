defmodule Test.Worker.WorkerQueueTest do
  use ExUnit.Case, async: false

  @hub_id :worker_queue_test_hub

  setup_all do
    Test.Helper.SetupHelper.setup_base(%{}, @hub_id)
  end

  describe "handle_cast {:handle_work}" do
    test "executes the function", %{hub: hub} do
      wq_pid = GenServer.whereis(hub.procs.worker_queue)
      assert is_pid(wq_pid)

      test_pid = self()
      GenServer.cast(wq_pid, {:handle_work, fn -> send(test_pid, :cast_work_done) end})
      assert_receive :cast_work_done, 1000
    end
  end

  describe "handle_call {:handle_work}" do
    test "executes the function and returns result", %{hub: hub} do
      wq_pid = GenServer.whereis(hub.procs.worker_queue)
      assert is_pid(wq_pid)

      result = GenServer.call(wq_pid, {:handle_work, fn -> :call_result end})
      assert result == :call_result
    end
  end
end
