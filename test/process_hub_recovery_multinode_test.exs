defmodule Test.ProcessHubRecoveryMultiNodeTest do
  @moduledoc """
  Multi-node integration tests for the opt-in coordinator boot-recovery
  lifecycle. Uses `:peer.start_link/1` (via `Test.Helper.TestNode`) to spin
  up real peer BEAM nodes.

  Covered scenarios:

    * 7.3 single-node-rejoin — peer reports `:normal`, B skips replay
    * 7.6 hook integration — `pre_recovery_replay` blocks; handler crash
      is isolated and replay proceeds anyway

  Cluster-wide cold-boot stampede (7.2), the stuck-`:recovery_pending`
  safety net (7.4), and old-peer mixed-version graceful degradation (7.5)
  are exercised by `process_hub_recovery_test.exs` (single-node, 7.4) and
  by the unit tests in `recovery_test.exs` (compute_transition + state
  invariants), where adding the additional peer dimension would not
  meaningfully exercise new code paths.
  """

  use ExUnit.Case, async: false

  alias Test.Helper.TestNode
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager

  setup_all do
    peer_nodes = TestNode.start_nodes(1, prefix: "recovery_mn")

    Enum.each(peer_nodes, fn {_, pid} -> :erlang.unlink(pid) end)

    on_exit(fn ->
      Enum.each(peer_nodes, fn {_, pid} ->
        if Process.alive?(pid), do: :peer.stop(pid)
      end)
    end)

    {:ok, %{peer_nodes: peer_nodes}}
  end

  defp unique_id(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  test "7.3 single-node rejoin — peer :normal causes skip-replay path", %{
    peer_nodes: [{peer_name, _peer_pid}]
  } do
    hub_id = unique_id(:rejoin)
    parent = self()

    # Start the hub on the peer first, in default (no auto_recovery) mode
    # so its coordinator is immediately :normal. Use the remote-callable
    # helper which start_link's AND unlinks on the peer side, so the hub
    # survives this RPC call returning.
    :erpc.call(peer_name, Test.Helper.Bootstrap, :start_hub_on_node, [
      %ProcessHub{hub_id: hub_id, hubs_discover_interval: 200},
      %{}
    ])

    # Wait for peer's coordinator to report :normal.
    assert :normal = :erpc.call(peer_name, ProcessHub, :recovery_state, [hub_id])

    # Give pg a moment to settle so peer's handlers are visible from local.
    Process.sleep(200)

    # Now start the local hub with auto_recovery enabled. The cluster_join
    # event should arrive within the recovery window, the peer should
    # respond with :normal, and we should transition directly to :normal
    # without entering :recovering.

    hooks = %{
      Hook.recovery_state_changed() => [
        %HookManager{
          id: :rejoin_hook,
          m: __MODULE__,
          f: :forward_to,
          a: [parent, :rejoin_state, :_]
        }
      ],
      Hook.pre_recovery_replay() => [
        %HookManager{
          id: :rejoin_pre_replay,
          m: __MODULE__,
          f: :forward_to,
          a: [parent, :rejoin_pre_replay, :_]
        }
      ]
    }

    {:ok, pid} =
      ProcessHub.Initializer.start_link(%ProcessHub{
        hub_id: hub_id,
        hooks: hooks,
        cluster_event_debounce: 0,
        hubs_discover_interval: 200,
        auto_recovery: [recovery_window_ms: 5_000, replay_timeout_ms: 5_000]
      })

    :erlang.unlink(pid)

    on_exit(fn ->
      ProcessHub.Initializer.stop(hub_id)
      :erpc.call(peer_name, ProcessHub.Initializer, :stop, [hub_id])
    end)

    # Expect the deferred-to-peers transition. We may also see a
    # :recovery_pending hook if the announce path includes one — but the
    # implementation only fires `recovery_state_changed` on transitions.
    assert_receive {:rejoin_state,
                    %{from: :recovery_pending, to: :normal, reason: :peer_normal}},
                   8_000

    # We must NOT see a transition to :recovering, and pre_replay must NOT
    # have fired.
    refute_receive {:rejoin_state, %{to: :recovering}}, 200
    refute_receive {:rejoin_pre_replay, _}, 200

    assert ProcessHub.recovery_state(hub_id) == :normal
  end

  test "7.6 hook integration — pre_recovery_replay blocks until handler returns; crash is isolated" do
    hub_id = unique_id(:hook_block)
    parent = self()

    hooks = %{
      Hook.pre_recovery_replay() => [
        %HookManager{
          id: :slow_handler,
          m: __MODULE__,
          f: :slow_pre_replay,
          a: [parent, :_]
        },
        %HookManager{
          id: :crashing_handler,
          m: __MODULE__,
          f: :crashing_pre_replay,
          a: [parent, :_]
        }
      ],
      Hook.post_recovery_replay() => [
        %HookManager{
          id: :post_marker,
          m: __MODULE__,
          f: :forward_to,
          a: [parent, :post_replay, :_]
        }
      ]
    }

    {:ok, pid} =
      ProcessHub.Initializer.start_link(%ProcessHub{
        hub_id: hub_id,
        hooks: hooks,
        auto_recovery: [recovery_window_ms: 1_000, replay_timeout_ms: 5_000]
      })

    :erlang.unlink(pid)
    on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)

    # The slow handler signals as it enters; we use the timestamp delta
    # from there to post_replay to confirm blocking.
    assert_receive {:slow_pre_replay_entered, t_entered}, 3_000

    # The crashing handler should have its crash caught — after slow returns.
    assert_receive {:crashing_pre_replay_entered, _t}, 3_000

    # Post-replay still fires: handler crash did not prevent the lifecycle.
    assert_receive {:post_replay, _payload}, 3_000

    # Confirm the lifecycle finished.
    assert ProcessHub.await_normal(hub_id, 2_000) == :ok

    t_now = System.monotonic_time(:millisecond)
    # The slow handler sleeps for 300 ms; we expect at least 250 ms between
    # entry and the lifecycle finishing.
    assert t_now - t_entered >= 250
  end

  # ---- Hook-handler helpers (called by the coordinator) ---------------------

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
