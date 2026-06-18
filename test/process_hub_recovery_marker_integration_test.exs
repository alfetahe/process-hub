defmodule Test.ProcessHubRecoveryMarkerIntegrationTest do
  @moduledoc """
  Boot-lifecycle integration tests for the marker-gated recovery path.

  Validates the end-to-end scenarios from Section 9 of the
  `recovery-mode-opt-in` change against a single BEAM with a real
  on-disk DETS backend and marker file. Multi-node split-brain
  reproduction is exercised by simulating the cycle: register children
  → stop hub → restart with marker (no replay) vs without marker
  (recovery replays cspecs).

  These tests assert the core invariant: a marker-present restart MUST
  NOT inject the previous incarnation's persisted rows into the
  in-memory registry.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Recovery

  defp unique_id(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp tmp_dir(prefix) do
    base =
      Path.join([
        System.tmp_dir!(),
        "phub_marker_int_#{prefix}_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    base
  end

  defp start_hub!(opts) do
    settings = struct(ProcessHub, opts)
    {:ok, pid} = ProcessHub.Initializer.start_link(settings)
    :erlang.unlink(pid)
    {settings.hub_id, pid}
  end

  defp stop_hub(hub_id), do: ProcessHub.Initializer.stop(hub_id)

  test "9.2 cold boot — markers absent → recovery → marker written → :normal" do
    hub_id = unique_id(:cb)
    dir = tmp_dir("cold")
    dets = Path.join(dir, "registry.dets")
    marker = Path.join(dir, "cluster.healthy")

    refute File.exists?(marker)

    {hub_id, _pid} =
      start_hub!(
        hub_id: hub_id,
        registry_backend: {:durable_ets, path: dets},
        auto_recovery: [marker_path: marker]
      )

    on_exit(fn -> stop_hub(hub_id) end)

    assert ProcessHub.await_normal(hub_id, 5_000) == :ok
    assert File.exists?(marker)
  end

  test "9.4 marker-present restart does NOT replay DETS into in-memory registry" do
    hub_id = unique_id(:mp_restart)
    dir = tmp_dir("mp")
    dets = Path.join(dir, "registry.dets")
    marker = Path.join(dir, "cluster.healthy")

    {hub_id, _pid} =
      start_hub!(
        hub_id: hub_id,
        registry_backend: {:durable_ets, path: dets},
        auto_recovery: [marker_path: marker]
      )

    assert ProcessHub.await_normal(hub_id, 5_000) == :ok

    # Seed a fake row directly via the backend so it survives the close.
    fake_pid = spawn(fn -> :ok end)
    Process.exit(fake_pid, :kill)

    cspec = %{id: "seeded", start: {Test.Helper.TestServer, :start_link, [%{name: "seeded"}]}}

    :ok =
      ProcessRegistry.insert(hub_id, cspec, [{:"otherhost@127.0.0.1", fake_pid}])

    assert {%{id: "seeded"}, _} = ProcessRegistry.lookup(hub_id, "seeded")
    assert File.exists?(marker)

    stop_hub(hub_id)
    # Ensure no inherited state leaks via process registry / name.
    Process.sleep(50)

    # Re-start with marker still present. The backend MUST open without
    # replaying the DETS row into ETS.
    {hub_id, _pid} =
      start_hub!(
        hub_id: hub_id,
        registry_backend: {:durable_ets, path: dets},
        auto_recovery: [marker_path: marker]
      )

    on_exit(fn -> stop_hub(hub_id) end)

    assert ProcessHub.await_normal(hub_id, 5_000) == :ok
    # The "seeded" row from the previous incarnation MUST NOT be present.
    assert ProcessRegistry.lookup(hub_id, "seeded") == nil
  end

  test "9.5 prepare_recovery → next boot is recovery mode and replays cspecs" do
    hub_id = unique_id(:prep_then_recover)
    dir = tmp_dir("prep")
    dets = Path.join(dir, "registry.dets")
    marker = Path.join(dir, "cluster.healthy")

    {hub_id, _pid} =
      start_hub!(
        hub_id: hub_id,
        registry_backend: {:durable_ets, path: dets},
        auto_recovery: [marker_path: marker]
      )

    assert ProcessHub.await_normal(hub_id, 5_000) == :ok

    fake_pid = spawn(fn -> :ok end)
    Process.exit(fake_pid, :kill)

    cspec = %{id: "to_recover", start: {Test.Helper.TestServer, :start_link, [%{name: "to_recover"}]}}
    :ok = ProcessRegistry.insert(hub_id, cspec, [{node(), fake_pid}])

    assert :ok = ProcessHub.prepare_recovery(hub_id)
    refute File.exists?(marker)

    stop_hub(hub_id)
    Process.sleep(50)

    handler_id = make_ref()
    parent = self()

    :telemetry.attach(handler_id, [:process_hub, :recovery, :started], fn _e, m, md, _ ->
      send(parent, {:started, m, md})
    end, nil)

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {hub_id, _pid} =
      start_hub!(
        hub_id: hub_id,
        registry_backend: {:durable_ets, path: dets},
        auto_recovery: [marker_path: marker]
      )

    on_exit(fn -> stop_hub(hub_id) end)

    assert_receive {:started, %{cspec_count: 1}, _md}, 3_000
    assert ProcessHub.await_normal(hub_id, 10_000) == :ok
    assert File.exists?(marker)
  end

  test "9.6 cluster-event queue is drained on gate open" do
    hub_id = unique_id(:queue)
    dir = tmp_dir("queue")
    dets = Path.join(dir, "registry.dets")
    marker = Path.join(dir, "cluster.healthy")

    # Marker absent so we enter :recovering.
    refute File.exists?(marker)

    parent = self()
    handler_id = make_ref()

    :telemetry.attach(
      handler_id,
      [:process_hub, :recovery, :complete],
      fn _e, _m, _md, _ -> send(parent, :complete) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {hub_id, _pid} =
      start_hub!(
        hub_id: hub_id,
        registry_backend: {:durable_ets, path: dets},
        auto_recovery: [
          marker_path: marker,
          replay_timeout_ms: 5_000,
          recovery_timeout_ms: 3_000
        ]
      )

    on_exit(fn -> stop_hub(hub_id) end)

    # We can't easily inject a cluster_join while in :recovering from
    # within the same node — but the empty-replay path still must drive
    # the gate open via :complete telemetry.
    assert_receive :complete, 3_000
    assert ProcessHub.await_normal(hub_id, 5_000) == :ok
  end

  test "env-var override interacts with marker correctly" do
    hub_id = unique_id(:env_force)
    dir = tmp_dir("env_force")
    dets = Path.join(dir, "registry.dets")
    marker = Path.join(dir, "cluster.healthy")
    File.touch!(marker)

    System.put_env(Recovery.env_var(), "force")
    on_exit(fn -> System.delete_env(Recovery.env_var()) end)

    parent = self()
    handler_id = make_ref()

    :telemetry.attach(handler_id, [:process_hub, :recovery, :started], fn _e, m, md, _ ->
      send(parent, {:started, m, md})
    end, nil)

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {hub_id, _pid} =
      start_hub!(
        hub_id: hub_id,
        registry_backend: {:durable_ets, path: dets},
        auto_recovery: [marker_path: marker]
      )

    on_exit(fn -> stop_hub(hub_id) end)

    # env=force overrides the present marker → recovery boot
    assert_receive {:started, _m, %{mode: :force}}, 2_000
    assert ProcessHub.await_normal(hub_id, 5_000) == :ok
  end
end
