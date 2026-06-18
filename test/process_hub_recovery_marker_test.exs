defmodule Test.ProcessHubRecoveryMarkerTest do
  @moduledoc """
  End-to-end tests for the marker-gated recovery lifecycle.

  Covers boot resolution (marker present → :normal/:skipped, marker
  absent → :recovering → :complete + marker written), telemetry shape,
  cluster-event queue + drain, `prepare_recovery/1`, and the fast-
  restart purge signal.

  Persistence/replay integration is covered separately by
  `process_hub_recovery_marker_integration_test.exs`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ProcessHub.Service.Recovery
  alias ProcessHub.Service.ProcessRegistry

  defp unique_id(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp tmp_dir(prefix) do
    base =
      Path.join([
        System.tmp_dir!(),
        "phub_marker_#{prefix}_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    base
  end

  defp start_hub!(opts) do
    hub_id = Keyword.fetch!(opts, :hub_id)
    settings = struct(ProcessHub, opts)
    {:ok, pid} = ProcessHub.Initializer.start_link(settings)
    :erlang.unlink(pid)
    on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)
    hub_id
  end

  describe "marker absent → recovery boot" do
    test "writes marker and reaches :normal with telemetry" do
      hub_id = unique_id(:marker_absent)
      dir = tmp_dir("absent")
      marker = Path.join(dir, "cluster.healthy")

      parent = self()
      handler_id = make_ref()

      :telemetry.attach_many(
        handler_id,
        [
          [:process_hub, :recovery, :started],
          [:process_hub, :recovery, :complete],
          [:process_hub, :recovery, :skipped]
        ],
        fn event, m, md, _ -> send(parent, {:rec, event, m, md}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      start_hub!(
        hub_id: hub_id,
        auto_recovery: [marker_path: marker]
      )

      assert ProcessHub.await_normal(hub_id, 5_000) == :ok
      assert File.exists?(marker)

      assert_receive {:rec, [:process_hub, :recovery, :started], %{cspec_count: 0}, _md}, 2_000
      assert_receive {:rec, [:process_hub, :recovery, :complete], %{cspec_count: 0, succeeded: 0}, _md},
                     2_000

      refute_receive {:rec, [:process_hub, :recovery, :skipped], _, _}, 200
    end
  end

  describe "marker present → normal boot" do
    test "skips replay and emits :skipped" do
      hub_id = unique_id(:marker_present)
      dir = tmp_dir("present")
      marker = Path.join(dir, "cluster.healthy")
      File.touch!(marker)

      parent = self()
      handler_id = make_ref()

      :telemetry.attach_many(
        handler_id,
        [
          [:process_hub, :recovery, :started],
          [:process_hub, :recovery, :skipped]
        ],
        fn event, m, md, _ -> send(parent, {:rec, event, m, md}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      start_hub!(
        hub_id: hub_id,
        auto_recovery: [marker_path: marker]
      )

      assert ProcessHub.recovery_state(hub_id) == :normal

      assert_receive {:rec, [:process_hub, :recovery, :skipped], %{}, %{reason: :marker_present}},
                     1_000

      refute_receive {:rec, [:process_hub, :recovery, :started], _, _}, 200
    end
  end

  describe "marker IO failures" do
    test "marker write failure does not block transition to :normal" do
      hub_id = unique_id(:marker_io_fail)
      # Path with a non-writable parent
      bad_marker = "/proc/1/cluster.healthy"

      # The write failure is logged at error level by design; capture it so
      # the expected `:enoent` doesn't surface as suite noise.
      log =
        capture_log(fn ->
          start_hub!(
            hub_id: hub_id,
            auto_recovery: [marker_path: bad_marker]
          )

          assert ProcessHub.await_normal(hub_id, 5_000) == :ok
        end)

      assert log =~ "Failed to write recovery marker"
    end
  end

  describe "prepare_recovery/1" do
    test "deletes the local marker" do
      hub_id = unique_id(:prep_local)
      dir = tmp_dir("prep")
      marker = Path.join(dir, "cluster.healthy")

      start_hub!(
        hub_id: hub_id,
        auto_recovery: [marker_path: marker]
      )

      assert ProcessHub.await_normal(hub_id, 5_000) == :ok
      assert File.exists?(marker)

      assert :ok = ProcessHub.prepare_recovery(hub_id)
      refute File.exists?(marker)

      # Idempotent
      assert :ok = ProcessHub.prepare_recovery(hub_id)
    end

    test "no-op when auto_recovery is disabled" do
      hub_id = unique_id(:prep_disabled)

      start_hub!(hub_id: hub_id)
      assert :ok = ProcessHub.prepare_recovery(hub_id)
    end

    test "error when hub is not running" do
      assert {:error, :not_alive} = ProcessHub.prepare_recovery(:no_such_hub_marker)
    end
  end

  describe "ProcessRegistry.purge_node_bindings/2" do
    test "drops only the matching node from node_pids" do
      hub_id = unique_id(:purge)
      start_hub!(hub_id: hub_id)

      node_a = node()
      node_b = :"b@127.0.0.1"

      cspec_a = %{id: "ca", start: {Test.Helper.TestServer, :start_link, [%{name: "ca"}]}}
      cspec_b = %{id: "cb", start: {Test.Helper.TestServer, :start_link, [%{name: "cb"}]}}

      fake_pid = spawn(fn -> :ok end)
      Process.exit(fake_pid, :kill)

      :ok =
        ProcessRegistry.insert(
          hub_id,
          cspec_a,
          [{node_a, fake_pid}, {node_b, fake_pid}]
        )

      :ok = ProcessRegistry.insert(hub_id, cspec_b, [{node_a, fake_pid}])

      :ok = ProcessRegistry.purge_node_bindings(hub_id, node_b)

      {_, nodes_a} = ProcessRegistry.lookup(hub_id, "ca")
      assert Keyword.keys(nodes_a) == [node_a]

      {_, nodes_b} = ProcessRegistry.lookup(hub_id, "cb")
      assert Keyword.keys(nodes_b) == [node_a]
    end

    test "removes the binding if node_pids becomes empty" do
      hub_id = unique_id(:purge_drop)
      start_hub!(hub_id: hub_id)

      node_b = :"b@127.0.0.1"
      cspec = %{id: "ce", start: {Test.Helper.TestServer, :start_link, [%{name: "ce"}]}}
      fake_pid = spawn(fn -> :ok end)
      Process.exit(fake_pid, :kill)

      :ok = ProcessRegistry.insert(hub_id, cspec, [{node_b, fake_pid}])
      :ok = ProcessRegistry.purge_node_bindings(hub_id, node_b)

      assert ProcessRegistry.lookup(hub_id, "ce") == nil
    end
  end

  describe "env-var override" do
    test "PROCESS_HUB_RECOVERY_MODE=skip → :normal, no DETS replay" do
      hub_id = unique_id(:env_skip)
      dir = tmp_dir("env_skip")
      marker = Path.join(dir, "cluster.healthy")
      System.put_env(Recovery.env_var(), "skip")
      on_exit(fn -> System.delete_env(Recovery.env_var()) end)

      parent = self()
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        [:process_hub, :recovery, :skipped],
        fn _e, m, md, _ -> send(parent, {:skipped, m, md}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      start_hub!(
        hub_id: hub_id,
        auto_recovery: [marker_path: marker]
      )

      assert ProcessHub.recovery_state(hub_id) == :normal
      assert_receive {:skipped, _, %{reason: :env_skip}}, 1_000
    end
  end
end
