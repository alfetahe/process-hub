defmodule Test.CoordinatorResponsivenessTest do
  @moduledoc """
  The coordinator is the hub's single serialising process. These tests pin that
  it keeps answering while the work around it is slow, that the shared worker
  queue keeps working while it is busy, and that its restart keeps the hub's
  storage. The multi-node case lives in
  `test/coordinator_responsiveness_multinode_test.exs`.
  """

  use ExUnit.Case, async: false
  use ProcessHub.Constant.Event

  alias ProcessHub.Strategy.Synchronization.PubSub
  alias Test.Helper.Common
  alias Test.Helper.SetupHelper

  defmodule HangingManifest do
    @moduledoc false
    @behaviour ProcessHub.Storage.RemoteManifest

    @flag {__MODULE__, :hang}

    def hang(on?), do: :persistent_term.put(@flag, on?)

    @impl true
    def store(_hub_id, _version, _blob, _opts), do: :ok

    @impl true
    def fetch(_hub_id, _opts) do
      if :persistent_term.get(@flag, false) do
        receive do
          :never -> :not_found
        end
      else
        :not_found
      end
    end

    @impl true
    def info(_opts), do: %{adapter: :hanging}

    @impl true
    def validate_config(_opts), do: :ok
  end

  # Lines three jobs up behind a stalled coordinator, in a known order: a peer's
  # sync round, the coordinator's own tracked job (it counts that one out and
  # waits for it back), then a marker that tells the test the queue drained.
  # Returns the queue and whether it drained or went down.
  defp line_up_behind_stalled_sync(hub_id) do
    hub = ProcessHub.Hub.get(hub_id)
    wq = GenServer.whereis(hub.procs.worker_queue)
    ref = Process.monitor(wq)
    test_pid = self()

    GenServer.cast(wq, {:handle_work, fn -> receive(do: (:release -> :ok)) end})
    PubSub.remote_sync_cast(hub.procs.worker_queue, hub_id, %PubSub{}, [], :peer@nowhere)
    send(hub_id, :sync_processes)
    assert ProcessHub.is_locked?(hub_id), "the coordinator's tracked job should be counted out"
    GenServer.cast(wq, {:handle_work, fn -> send(test_pid, :drained) end})

    :sys.suspend(hub_id)
    on_exit(fn -> :sys.resume(hub_id) end)
    send(wq, :release)

    receive do
      :drained -> {wq, :drained}
      {:DOWN, ^ref, :process, ^wq, reason} -> {wq, {:down, reason}}
    after
      10_000 -> flunk("the worker queue neither drained nor stopped")
    end
  end

  describe "the worker queue" do
    test "survives a peer's sync job while the coordinator is busy" do
      hub_id = SetupHelper.unique_id(:resp_queue_alive)
      {^hub_id, _pid} = SetupHelper.start_hub!(hub_id: hub_id)

      assert {wq, :drained} = line_up_behind_stalled_sync(hub_id)
      assert GenServer.whereis(ProcessHub.Hub.get(hub_id).procs.worker_queue) === wq
    end

    test "does not leave the hub locked behind a busy coordinator" do
      hub_id = SetupHelper.unique_id(:resp_queue_lock)
      {^hub_id, _pid} = SetupHelper.start_hub!(hub_id: hub_id)

      line_up_behind_stalled_sync(hub_id)
      :sys.resume(hub_id)

      assert Common.eventually(fn -> not ProcessHub.is_locked?(hub_id) end),
             "the hub stays locked: a job lost with the queue never reported back"
    end
  end

  describe "a coordinator restart" do
    test "keeps the registry it was started with" do
      hub_id = SetupHelper.unique_id(:resp_restart)
      {^hub_id, _pid} = SetupHelper.start_hub!(hub_id: hub_id)
      coordinator = Process.whereis(hub_id)
      ref = Process.monitor(coordinator)

      ExUnit.CaptureLog.capture_log(fn ->
        GenServer.cast(hub_id, {:exec_cast, {:erlang, :error, []}})
        assert_receive {:DOWN, ^ref, :process, ^coordinator, _}, 1_000
      end)

      assert Common.eventually(fn -> Process.whereis(hub_id) not in [nil, coordinator] end)

      spec = %{id: :after_restart, start: {Test.Helper.TestServer, :start_link, [%{}]}}
      ProcessHub.Service.ProcessRegistry.insert(hub_id, spec, [{node(), self()}])
      assert ProcessHub.Service.ProcessRegistry.lookup(hub_id, :after_restart)
    end
  end

  describe "the coordinator keeps answering" do
    # 1 — a peer's whole registry arrives when nodes join, as children migrate.
    test "while it merges a peer's registry" do
      hub_id = SetupHelper.unique_id(:resp_merge)
      {^hub_id, _pid} = SetupHelper.start_hub!(hub_id: hub_id)
      hub = ProcessHub.Hub.get(hub_id)

      # A slow registry stands in for a large payload merged one row at a time.
      registry = GenServer.whereis(hub.procs.process_registry)
      :sys.suspend(registry)
      on_exit(fn -> if Process.alive?(registry), do: :sys.resume(registry) end)

      row = {%{id: :peer_child, start: {Test.Helper.TestServer, :start_link, [%{}]}}, self(), %{}}
      send(hub_id, {@event_node_registry_broadcast, {{[row], 1}, :peer@nowhere}})

      assert Common.answers_within?(hub_id, 1_000)
    end

    # 4 — re-fetching the off-cluster manifest after it was unreachable at boot.
    test "while it re-fetches the remote manifest" do
      hub_id = SetupHelper.unique_id(:resp_refetch)

      {^hub_id, _pid} =
        SetupHelper.start_hub!(
          hub_id: hub_id,
          auto_recovery: [reconcile_grace_ms: 600_000, remote_manifest: {HangingManifest, []}]
        )

      HangingManifest.hang(true)
      on_exit(fn -> HangingManifest.hang(false) end)
      send(hub_id, :declared_remote_refetch)

      assert Common.answers_within?(hub_id, 1_000)
    end
  end
end
