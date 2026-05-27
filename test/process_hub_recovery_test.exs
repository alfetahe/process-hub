defmodule Test.ProcessHubRecoveryTest do
  @moduledoc """
  End-to-end tests for the opt-in coordinator boot-recovery lifecycle.

  Each test starts a real `ProcessHub` instance and exercises the
  three-state machine via the public API and hooks. Multi-node scenarios
  are covered separately in `test/integration_test.exs`.
  """

  use ExUnit.Case, async: false

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

      parent = self()

      hooks = %{
        Hook.recovery_state_changed() => [
          %HookManager{
            id: :default_no_hook,
            m: __MODULE__,
            f: :forward_to,
            a: [parent, :state_changed, :_]
          }
        ]
      }

      start_hub!(hub_id: hub_id, hooks: hooks)
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

  describe "auto_recovery: true" do
    test "starts in :recovery_pending and transitions to :normal after window" do
      hub_id = unique_id(:recovery_pending_basic)

      parent = self()

      hooks = %{
        Hook.recovery_state_changed() => [
          %HookManager{
            id: :basic_state_changed,
            m: __MODULE__,
            f: :forward_to,
            a: [parent, :state_changed, :_]
          }
        ]
      }

      start_hub!(
        hub_id: hub_id,
        hooks: hooks,
        auto_recovery: [recovery_window_ms: 1_000, replay_timeout_ms: 5_000],
        recovery_marker: %{enabled?: false}
      )

      # Initial state observation must be :recovery_pending — the GenServer
      # is alive immediately after start_link returns.
      assert ProcessHub.recovery_state(hub_id) == :recovery_pending

      # After the window elapses (no peers), we transition to :recovering
      # then to :normal.
      assert_receive {:state_changed,
                      %{from: :recovery_pending, to: :recovering, reason: :window_elapsed}},
                     3_000

      assert_receive {:state_changed, %{from: :recovering, to: :normal}}, 3_000

      assert ProcessHub.recovery_state(hub_id) == :normal
    end

    test "await_normal/2 blocks until transition" do
      hub_id = unique_id(:recovery_await_block)

      start_hub!(
        hub_id: hub_id,
        auto_recovery: [recovery_window_ms: 1_000, replay_timeout_ms: 5_000],
        recovery_marker: %{enabled?: false}
      )

      assert ProcessHub.recovery_state(hub_id) == :recovery_pending
      assert ProcessHub.await_normal(hub_id, 5_000) == :ok
      assert ProcessHub.recovery_state(hub_id) == :normal
    end

    test "await_normal/2 returns :timeout when too slow" do
      hub_id = unique_id(:recovery_await_timeout)

      start_hub!(
        hub_id: hub_id,
        auto_recovery: [recovery_window_ms: 5_000, replay_timeout_ms: 5_000],
        recovery_marker: %{enabled?: false}
      )

      assert ProcessHub.recovery_state(hub_id) == :recovery_pending
      assert ProcessHub.await_normal(hub_id, 200) == {:error, :timeout}
    end

    test "pre/post_recovery_replay hooks fire on the replay path" do
      hub_id = unique_id(:recovery_replay_hooks)

      parent = self()

      hooks = %{
        Hook.pre_recovery_replay() => [
          %HookManager{
            id: :pre_replay,
            m: __MODULE__,
            f: :forward_to,
            a: [parent, :pre_replay, :_]
          }
        ],
        Hook.post_recovery_replay() => [
          %HookManager{
            id: :post_replay,
            m: __MODULE__,
            f: :forward_to,
            a: [parent, :post_replay, :_]
          }
        ]
      }

      start_hub!(
        hub_id: hub_id,
        hooks: hooks,
        auto_recovery: [recovery_window_ms: 1_000, replay_timeout_ms: 5_000],
        recovery_marker: %{enabled?: false}
      )

      assert_receive {:pre_replay, %{hub_id: ^hub_id, child_count: 0}}, 3_000
      assert_receive {:post_replay, %{hub_id: ^hub_id, child_count: 0, succeeded: 0, failed: 0}},
                     3_000
    end
  end

  describe "invalid auto_recovery config" do
    test "out-of-range value refuses to start" do
      hub_id = unique_id(:recovery_bad)

      Process.flag(:trap_exit, true)

      result =
        ProcessHub.Initializer.start_link(%ProcessHub{
          hub_id: hub_id,
          auto_recovery: [recovery_window_ms: 1]
        })

      assert match?({:error, _}, result)
    end
  end

  describe "telemetry" do
    test "recovery_replay_started/completed events emit" do
      hub_id = unique_id(:recovery_telemetry)
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

      start_hub!(
        hub_id: hub_id,
        auto_recovery: [recovery_window_ms: 1_000, replay_timeout_ms: 5_000],
        recovery_marker: %{enabled?: false}
      )

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

  describe "no recovery timer scheduled when disabled" do
    test "no :recovery_window_elapsed message reaches the coordinator" do
      hub_id = unique_id(:recovery_no_timer)

      parent = self()

      hooks = %{
        Hook.recovery_state_changed() => [
          %HookManager{
            id: :no_timer_hook,
            m: __MODULE__,
            f: :forward_to,
            a: [parent, :state_changed, :_]
          }
        ]
      }

      start_hub!(hub_id: hub_id, hooks: hooks)

      # If a window were scheduled with the default 10s, we'd time it out
      # here, but disabled mode never schedules so we expect nothing.
      refute_receive {:state_changed, _}, 300
      assert ProcessHub.recovery_state(hub_id) == :normal
    end
  end

  # Public helper used by hook handlers to forward payloads to the test pid.
  def forward_to(pid, tag, payload), do: send(pid, {tag, payload})
end
