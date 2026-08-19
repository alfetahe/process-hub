defmodule Test.ProcessHubRecoveryTest do
  @moduledoc """
  Covers the opt-in coordinator boot-recovery feature end to end: the pure
  `ProcessHub.Service.Recovery` helpers (config, marker IO, mode resolution) and
  the live `:recovering → :normal` lifecycle driven through a real hub via the
  `recovery_state_changed` hook. Multi-node scenarios live in
  `test/integration_test.exs`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Recovery

  defp unique_id(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp tmp_path(suffix \\ "") do
    Path.join(System.tmp_dir!(), "phub_rec_#{System.unique_integer([:positive])}#{suffix}")
  end

  defp tmp_marker do
    path = tmp_path()
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  # ---------------------------------------------------------------------------
  # Pure helpers
  # ---------------------------------------------------------------------------

  describe "parse_config/1" do
    test "false / true / keyword shapes" do
      assert {:ok, %{enabled?: false, recovery_timeout_ms: 30_000, marker_path: nil}} =
               Recovery.parse_config(false)

      assert {:ok, %{enabled?: true, recovery_timeout_ms: 30_000, marker_path: nil}} =
               Recovery.parse_config(true)

      assert {:ok, %{enabled?: true, recovery_timeout_ms: 45_000, marker_path: "/x"}} =
               Recovery.parse_config(recovery_timeout_ms: 45_000, marker_path: "/x")
    end

    test "rejects out-of-range timeout, bad marker_path, and unknown shapes" do
      assert {:error, {:invalid_auto_recovery, :recovery_timeout_ms_out_of_range}} =
               Recovery.parse_config(recovery_timeout_ms: 100)

      assert {:error, {:invalid_auto_recovery, :recovery_timeout_ms_out_of_range}} =
               Recovery.parse_config(recovery_timeout_ms: 10_000_000)

      assert {:error, {:invalid_auto_recovery, :invalid_marker_path}} =
               Recovery.parse_config(marker_path: 123)

      assert {:error, :invalid_auto_recovery} = Recovery.parse_config(:bad)
    end
  end

  describe "init_marker/3 and resolve_mode/2" do
    test "disabled → :normal; absent → :recovering; present → :normal" do
      assert {%{enabled?: false, path: nil}, :normal, :normal} =
               Recovery.init_marker(:hub, nil, false)

      path = tmp_marker()

      assert {%{enabled?: true, path: ^path}, :recovering, :recovery} =
               Recovery.init_marker(:hub, path, true)

      File.touch!(path)

      assert {%{enabled?: true, path: ^path}, :normal, :normal} =
               Recovery.init_marker(:hub, path, true)
    end

    test "resolve_mode gates on the marker; disabled always :normal" do
      assert :recovery = Recovery.resolve_mode(false, true)
      assert :normal = Recovery.resolve_mode(true, true)
      assert :normal = Recovery.resolve_mode(false, false)
    end

    test "nil marker_path resolves under :user_data + hub_id" do
      assert Recovery.resolve_marker_path(:my_hub, nil) =~ "/my_hub/cluster.healthy"
      assert Recovery.resolve_marker_path(:hub, "/var/lib/x") == "/var/lib/x"
    end
  end

  # ---------------------------------------------------------------------------
  # Live lifecycle
  # ---------------------------------------------------------------------------

  defp start_hub!(opts) do
    hub_id = Keyword.fetch!(opts, :hub_id)
    {:ok, pid} = ProcessHub.Initializer.start_link(struct(ProcessHub, opts))
    :erlang.unlink(pid)
    on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)
    hub_id
  end

  # Forwards recovery_state_changed payloads to the test pid as {:sc, data}.
  defp sc_hook do
    [
      hooks: %{
        Hook.recovery_state_changed() => [
          %HookManager{id: :sc, m: __MODULE__, f: :forward_to, a: [self(), :sc, :_]}
        ]
      }
    ]
  end

  defp start_recovery_hub!(prefix, opts \\ []) do
    hub_id = unique_id(prefix)
    auto_recovery = Keyword.merge([marker_path: tmp_marker(), recovery_timeout_ms: 5_000], opts)
    start_hub!([hub_id: hub_id, auto_recovery: auto_recovery] ++ sc_hook())
    hub_id
  end

  def forward_to(pid, tag, payload), do: send(pid, {tag, payload})

  describe "disabled / non-existent hub" do
    test "recovery_state is :normal, await_normal is :ok, and no hook fires" do
      hub_id = start_hub!([hub_id: unique_id(:rec_default)] ++ sc_hook())
      assert Recovery.recovery_state(hub_id) == :normal
      assert Recovery.await_normal(hub_id, 100) == :ok
      refute_receive {:sc, _}, 200

      assert Recovery.recovery_state(:no_such_hub) == :normal
      assert Recovery.await_normal(:no_such_hub, 50) == :ok
    end
  end

  describe "marker absent → recovery boot" do
    test "fires init→recovering→normal, writes the marker, and await_normal unblocks" do
      hub_id = start_recovery_hub!(:rec_absent)

      assert_receive {:sc,
                      %{hub_id: ^hub_id, from: :init, to: :recovering, reason: :marker_absent}},
                     3_000

      assert_receive {:sc,
                      %{
                        to: :normal,
                        reason: :replay_complete,
                        measurements: %{cspec_count: 0, succeeded: 0}
                      }},
                     3_000

      assert Recovery.await_normal(hub_id, 5_000) == :ok
      assert Recovery.recovery_state(hub_id) == :normal
    end

    test "pre/post_recovery_replay hooks fire on the replay path" do
      parent = self()

      hooks = %{
        Hook.pre_recovery_replay() => [
          %HookManager{id: :pre, m: __MODULE__, f: :forward_to, a: [parent, :pre_replay, :_]}
        ],
        Hook.post_recovery_replay() => [
          %HookManager{id: :post, m: __MODULE__, f: :forward_to, a: [parent, :post_replay, :_]}
        ]
      }

      hub_id = unique_id(:rec_hooks)
      start_hub!(hub_id: hub_id, hooks: hooks, auto_recovery: [marker_path: tmp_marker()])

      assert_receive {:pre_replay, %{hub_id: ^hub_id, child_count: 0}}, 3_000

      assert_receive {:post_replay, %{hub_id: ^hub_id, child_count: 0, succeeded: 0, failed: 0}},
                     3_000
    end

    test "pre_recovery_replay blocks until handlers return; a handler crash is isolated" do
      parent = self()

      hooks = %{
        Hook.pre_recovery_replay() => [
          %HookManager{id: :slow, m: __MODULE__, f: :slow_pre_replay, a: [parent, :_]},
          %HookManager{id: :crash, m: __MODULE__, f: :crashing_pre_replay, a: [parent, :_]}
        ],
        Hook.post_recovery_replay() => [
          %HookManager{id: :post, m: __MODULE__, f: :forward_to, a: [parent, :post_replay, :_]}
        ]
      }

      hub_id = unique_id(:rec_block)

      log =
        capture_log(fn ->
          start_hub!(hub_id: hub_id, hooks: hooks, auto_recovery: [marker_path: tmp_marker()])

          assert_receive {:slow_entered, handler_pid}, 3_000
          # The slow handler blocks, so replay must not complete yet.
          refute_receive {:post_replay, _}, 100
          send(handler_pid, :release)
          assert_receive {:post_replay, _}, 3_000
          assert Recovery.await_normal(hub_id, 2_000) == :ok
        end)

      assert log =~ "intentional handler crash"
    end
  end

  describe "marker present → normal boot" do
    test "skips replay, firing init→normal with :marker_present and never :recovering" do
      marker = tmp_marker()
      File.touch!(marker)
      hub_id = unique_id(:rec_present)
      start_hub!([hub_id: hub_id, auto_recovery: [marker_path: marker]] ++ sc_hook())

      assert Recovery.recovery_state(hub_id) == :normal
      assert_receive {:sc, %{from: :init, to: :normal, reason: :marker_present}}, 1_000
      refute_receive {:sc, %{to: :recovering}}, 200
    end
  end

  describe "failure / edge cases" do
    test "marker write failure is logged but still reaches :normal" do
      hub_id = unique_id(:rec_io_fail)

      log =
        capture_log(fn ->
          start_hub!(hub_id: hub_id, auto_recovery: [marker_path: "/proc/1/cluster.healthy"])
          assert Recovery.await_normal(hub_id, 5_000) == :ok
        end)

      assert log =~ "Failed to write recovery marker"
    end

    test "an out-of-range config refuses to start" do
      Process.flag(:trap_exit, true)

      assert {:error, _} =
               ProcessHub.Initializer.start_link(%ProcessHub{
                 hub_id: unique_id(:rec_bad),
                 auto_recovery: [recovery_timeout_ms: 1]
               })
    end
  end

  describe "prepare_recovery/1" do
    test "deletes the local marker, is idempotent, and no-ops when not applicable" do
      marker = tmp_marker()
      hub_id = start_recovery_hub!(:rec_prep, marker_path: marker)
      assert Recovery.await_normal(hub_id, 5_000) == :ok
      assert File.exists?(marker)

      assert :ok = Recovery.prepare_recovery(hub_id)
      refute File.exists?(marker)
      assert :ok = Recovery.prepare_recovery(hub_id)

      no_ar = start_hub!(hub_id: unique_id(:rec_prep_off))
      assert :ok = Recovery.prepare_recovery(no_ar)
      assert {:error, :not_alive} = Recovery.prepare_recovery(:no_such_hub_marker)
    end
  end

  # ---------------------------------------------------------------------------
  # DETS-backed integration: the core "no stale replay into a healthy cluster"
  # invariant and the prepare_recovery → replay round-trip.
  # ---------------------------------------------------------------------------

  describe "durable registry integration" do
    defp start_dets_hub!(prefix) do
      dir = tmp_path("_dir")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      dets = Path.join(dir, "registry.dets")
      marker = Path.join(dir, "cluster.healthy")
      hub_id = unique_id(prefix)
      {hub_id, dets, marker}
    end

    defp boot_dets!(hub_id, dets, marker) do
      {:ok, pid} =
        ProcessHub.Initializer.start_link(%ProcessHub{
          hub_id: hub_id,
          registry_backend: {:durable_ets, path: dets},
          auto_recovery: [marker_path: marker]
        })

      :erlang.unlink(pid)
      on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)
      pid
    end

    defp restart!(hub_id, pid, dets, marker) do
      ref = Process.monitor(pid)
      ProcessHub.Initializer.stop(hub_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      boot_dets!(hub_id, dets, marker)
    end

    test "marker-present restart does NOT replay persisted rows into the registry" do
      {hub_id, dets, marker} = start_dets_hub!(:mp)
      pid = boot_dets!(hub_id, dets, marker)
      assert Recovery.await_normal(hub_id, 5_000) == :ok

      dead = spawn(fn -> :ok end)
      Process.exit(dead, :kill)
      cspec = %{id: "seeded", start: {Test.Helper.TestServer, :start_link, [%{name: "seeded"}]}}
      :ok = ProcessRegistry.insert(hub_id, cspec, [{:"other@127.0.0.1", dead}])

      # Marker still present → the returning node trusts peers, not local disk.
      _pid = restart!(hub_id, pid, dets, marker)
      assert Recovery.await_normal(hub_id, 5_000) == :ok
      assert ProcessRegistry.lookup(hub_id, "seeded") == nil
    end

    test "prepare_recovery arms the next boot to replay cspecs from disk" do
      {hub_id, dets, marker} = start_dets_hub!(:prep)
      pid = boot_dets!(hub_id, dets, marker)
      assert Recovery.await_normal(hub_id, 5_000) == :ok

      dead = spawn(fn -> :ok end)
      Process.exit(dead, :kill)
      cspec = %{id: "keep", start: {Test.Helper.TestServer, :start_link, [%{name: "keep"}]}}
      :ok = ProcessRegistry.insert(hub_id, cspec, [{node(), dead}])

      assert :ok = Recovery.prepare_recovery(hub_id)
      refute File.exists?(marker)

      hooks = %{
        Hook.recovery_state_changed() => [
          %HookManager{id: :sc, m: __MODULE__, f: :forward_to, a: [self(), :sc, :_]}
        ]
      }

      ref = Process.monitor(pid)
      ProcessHub.Initializer.stop(hub_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

      {:ok, pid2} =
        ProcessHub.Initializer.start_link(%ProcessHub{
          hub_id: hub_id,
          registry_backend: {:durable_ets, path: dets},
          auto_recovery: [marker_path: marker],
          hooks: hooks
        })

      :erlang.unlink(pid2)
      on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)

      assert_receive {:sc, %{to: :recovering, measurements: %{cspec_count: 1}}}, 3_000
      assert Recovery.await_normal(hub_id, 10_000) == :ok
      assert File.exists?(marker)
    end
  end

  # ---------------------------------------------------------------------------
  # Hook handlers
  # ---------------------------------------------------------------------------

  def slow_pre_replay(parent, _data) do
    send(parent, {:slow_entered, self()})

    receive do
      :release -> :ok
    after
      5_000 -> :ok
    end
  end

  def crashing_pre_replay(parent, _data) do
    send(parent, {:crash_entered, self()})
    raise "intentional handler crash"
  end
end
