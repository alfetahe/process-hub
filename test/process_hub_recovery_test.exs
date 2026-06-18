defmodule Test.ProcessHubRecoveryTest do
  @moduledoc """
  End-to-end tests for the opt-in coordinator boot-recovery lifecycle.

  Each test starts a real `ProcessHub` instance and exercises the
  three-state machine via the public API and hooks. Multi-node scenarios
  are covered separately in `test/integration_test.exs`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager

  defp unique_id(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp start_hub!(opts) do
    hub_id = Keyword.fetch!(opts, :hub_id)
    settings = struct(ProcessHub, opts)
    {:ok, pid} = ProcessHub.Initializer.start_link(settings)
    :erlang.unlink(pid)
    on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)
    hub_id
  end

  # Starts an auto_recovery hub with a fresh (absent) marker so boot takes
  # the recovery → replay path. Extra auto_recovery opts can be merged in.
  defp start_recovery_hub!(prefix, opts \\ []) do
    hub_id = unique_id(prefix)
    marker = Path.join(System.tmp_dir!(), "phub_rec_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(marker) end)
    auto_recovery = Keyword.merge([marker_path: marker, replay_timeout_ms: 5_000], opts)
    start_hub!([hub_id: hub_id, auto_recovery: auto_recovery] ++ state_changed_hook())
    hub_id
  end

  defp state_changed_hook do
    hooks = %{
      Hook.recovery_state_changed() => [
        %HookManager{id: :sc, m: __MODULE__, f: :forward_to, a: [self(), :state_changed, :_]}
      ]
    }

    [hooks: hooks]
  end

  describe "default config (no :auto_recovery)" do
    test "recovery_state/1 returns :normal immediately" do
      hub_id = unique_id(:recovery_default)
      start_hub!(hub_id: hub_id)
      assert ProcessHub.recovery_state(hub_id) == :normal
    end

    test "await_normal/2 returns :ok immediately" do
      hub_id = unique_id(:recovery_default_await)
      start_hub!(hub_id: hub_id)
      assert ProcessHub.await_normal(hub_id, 100) == :ok
    end

    test "recovery_state_changed hook does not fire on init" do
      hub_id = unique_id(:recovery_default_no_hook)
      start_hub!([hub_id: hub_id] ++ state_changed_hook())
      refute_receive {:state_changed, _}, 200
    end
  end

  describe "non-existent hub" do
    test "recovery_state/1 returns :normal" do
      assert ProcessHub.recovery_state(:does_not_exist_recovery) == :normal
    end

    test "await_normal/2 returns :ok" do
      assert ProcessHub.await_normal(:does_not_exist_recovery, 50) == :ok
    end
  end

  describe "auto_recovery enabled (marker absent)" do
    test "transitions :recovery_pending → :recovering → :normal via replay" do
      hub_id = start_recovery_hub!(:recovery_pending_basic)

      assert_receive {:state_changed,
                      %{from: :recovery_pending, to: :recovering, reason: :marker_absent}},
                     3_000

      assert_receive {:state_changed, %{from: :recovering, to: :normal}}, 3_000
      assert ProcessHub.recovery_state(hub_id) == :normal
    end

    test "await_normal/2 blocks until transition" do
      hub_id = start_recovery_hub!(:recovery_await_block)
      assert ProcessHub.await_normal(hub_id, 5_000) == :ok
      assert ProcessHub.recovery_state(hub_id) == :normal
    end

    test "pre/post_recovery_replay hooks fire on the replay path" do
      parent = self()

      hooks = %{
        Hook.pre_recovery_replay() => [
          %HookManager{id: :pre_replay, m: __MODULE__, f: :forward_to, a: [parent, :pre_replay, :_]}
        ],
        Hook.post_recovery_replay() => [
          %HookManager{id: :post_replay, m: __MODULE__, f: :forward_to, a: [parent, :post_replay, :_]}
        ]
      }

      hub_id = unique_id(:recovery_replay_hooks)
      marker = Path.join(System.tmp_dir!(), "phub_rec_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(marker) end)
      start_hub!(hub_id: hub_id, hooks: hooks, auto_recovery: [marker_path: marker])

      assert_receive {:pre_replay, %{hub_id: ^hub_id, child_count: 0}}, 3_000
      assert_receive {:post_replay, %{hub_id: ^hub_id, child_count: 0, succeeded: 0, failed: 0}},
                     3_000
    end

    test "pre_recovery_replay blocks until handler returns; handler crash is isolated" do
      parent = self()

      hooks = %{
        Hook.pre_recovery_replay() => [
          %HookManager{id: :slow, m: __MODULE__, f: :slow_pre_replay, a: [parent, :_]},
          %HookManager{id: :crashing, m: __MODULE__, f: :crashing_pre_replay, a: [parent, :_]}
        ],
        Hook.post_recovery_replay() => [
          %HookManager{id: :post, m: __MODULE__, f: :forward_to, a: [parent, :post_replay, :_]}
        ]
      }

      hub_id = unique_id(:hook_block)
      marker = Path.join(System.tmp_dir!(), "phub_rec_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(marker) end)

      # capture_log swallows the expected crash-isolation warning.
      log =
        capture_log(fn ->
          start_hub!(hub_id: hub_id, hooks: hooks, auto_recovery: [marker_path: marker])

          assert_receive {:slow_pre_replay_entered, t_entered}, 3_000
          assert_receive {:crashing_pre_replay_entered, _t}, 3_000
          assert_receive {:post_replay, _payload}, 3_000
          assert ProcessHub.await_normal(hub_id, 2_000) == :ok

          # The slow handler sleeps 300 ms; the lifecycle must have blocked on it.
          assert System.monotonic_time(:millisecond) - t_entered >= 250
        end)

      assert log =~ "intentional handler crash"
    end
  end

  describe "invalid auto_recovery config" do
    test "out-of-range value refuses to start" do
      hub_id = unique_id(:recovery_bad)
      Process.flag(:trap_exit, true)

      result =
        ProcessHub.Initializer.start_link(%ProcessHub{
          hub_id: hub_id,
          auto_recovery: [replay_timeout_ms: 1]
        })

      assert match?({:error, _}, result)
    end
  end

  describe "telemetry" do
    test "recovery_replay_started/completed events emit" do
      handler_id = make_ref()
      parent = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:process_hub, :coordinator, :recovery_replay_started],
          [:process_hub, :coordinator, :recovery_replay_completed]
        ],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      hub_id = start_recovery_hub!(:recovery_telemetry)

      assert_receive {:telemetry,
                      [:process_hub, :coordinator, :recovery_replay_started],
                      %{child_count: 0},
                      %{hub_id: ^hub_id}},
                     3_000

      assert_receive {:telemetry,
                      [:process_hub, :coordinator, :recovery_replay_completed],
                      %{child_count: 0, succeeded: 0, failed: 0, elapsed_ms: _},
                      %{hub_id: ^hub_id, reason: :empty}},
                     3_000
    end
  end

  describe "no recovery lifecycle when disabled" do
    test "no recovery_state_changed message reaches the coordinator" do
      hub_id = unique_id(:recovery_no_timer)
      start_hub!([hub_id: hub_id] ++ state_changed_hook())

      refute_receive {:state_changed, _}, 300
      assert ProcessHub.recovery_state(hub_id) == :normal
    end
  end

  # Public helpers used by hook handlers to forward payloads to the test pid.
  def forward_to(pid, tag, payload), do: send(pid, {tag, payload})

  def slow_pre_replay(parent, _hook_data) do
    send(parent, {:slow_pre_replay_entered, System.monotonic_time(:millisecond)})
    Process.sleep(300)
    :ok
  end

  def crashing_pre_replay(parent, _hook_data) do
    send(parent, {:crashing_pre_replay_entered, System.monotonic_time(:millisecond)})
    raise "intentional handler crash"
  end
end
