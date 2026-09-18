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

  describe "handle_cast {:tracked}" do
    test "executes the inner message and sends :work_complete to notify_pid", %{hub: hub} do
      wq_pid = GenServer.whereis(hub.procs.worker_queue)
      assert is_pid(wq_pid)

      test_pid = self()

      GenServer.cast(
        wq_pid,
        {:tracked, {:handle_work, fn -> send(test_pid, :tracked_work_done) end}, test_pid}
      )

      assert_receive :tracked_work_done, 1000
      assert_receive :work_complete, 1000
    end

    test "sends :work_complete even for non-function messages", %{hub: hub} do
      wq_pid = GenServer.whereis(hub.procs.worker_queue)
      test_pid = self()

      GenServer.cast(
        wq_pid,
        {:tracked, {:handle_work, fn -> :ok end}, test_pid}
      )

      assert_receive :work_complete, 1000
    end

    test "a job that raises, exits or throws is logged and still reports done",
         %{hub: hub} do
      wq_pid = GenServer.whereis(hub.procs.worker_queue)
      test_pid = self()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for fail <- [fn -> raise "boom" end, fn -> exit(:gone) end, fn -> throw(:up) end] do
            GenServer.cast(wq_pid, {:tracked, {:handle_work, fail}, test_pid})
            assert_receive :work_complete, 1000
          end

          GenServer.cast(wq_pid, {:handle_work, fn -> send(test_pid, :next_job_ran) end})
          assert_receive :next_job_ran, 1000
        end)

      assert GenServer.whereis(hub.procs.worker_queue) === wq_pid
      assert log =~ "[error]"
      assert log =~ "Worker queue job :handle_work failed"
      assert log =~ "boom"
      assert log =~ ":gone"
      assert log =~ ":up"
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
