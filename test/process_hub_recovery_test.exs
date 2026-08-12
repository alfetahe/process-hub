defmodule Test.ProcessHubRecoveryTest do
  @moduledoc """
  Covers the opt-in orphan reconcile end to end: `:auto_recovery` config parsing,
  the two-state `:recovering → :normal` lifecycle, the reconcile hooks, and the
  orphan arithmetic (durable candidates − observed − stopped) driven through a
  real hub on a durable backend. Multi-node scenarios live in
  `test/process_hub_reconcile_multinode_test.exs`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.ProcessRegistry.Row
  alias ProcessHub.Service.Recovery
  alias ProcessHub.Strategy.Synchronization.PubSub
  alias Test.Helper.SetupHelper

  # Rounds are triggered explicitly with `reconcile_now/1` rather than waited for,
  # so the grace window is set beyond any test's lifetime. Tests that assert the
  # *timer* path say so locally.
  @no_timer_grace_ms 600_000
  # The lowest interval the config accepts; only the two tests that genuinely need
  # a second round pay it.
  @interval_ms 1_000
  @sync_strategy %PubSub{sync_interval: 300}

  # Asks the coordinator to run a round now. `round_due?/1` still applies, so this
  # cannot produce a round the running system would not have allowed.
  defp reconcile_now(hub_id), do: send(hub_id, :reconcile_round)

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "ph_reconcile_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, %{tmp_dir: tmp_dir, dets: Path.join(tmp_dir, "registry.dets")}}
  end

  def forward_to(pid, tag, payload), do: send(pid, {tag, payload})

  # Drops hook messages from a previous hub incarnation so a restart's own
  # reports are the only ones in the mailbox.
  defp flush_hooks do
    receive do
      {tag, _payload} when tag in [:sc, :round, :pre_replay, :post_replay] -> flush_hooks()
    after
      0 -> :ok
    end
  end

  defp forwarding_hooks(tags) do
    Map.new(tags, fn {hook_key, tag} ->
      {hook_key, [%HookManager{id: tag, m: __MODULE__, f: :forward_to, a: [self(), tag, :_]}]}
    end)
  end

  defp default_hooks do
    forwarding_hooks(%{
      Hook.recovery_state_changed() => :sc,
      Hook.reconcile_round() => :round,
      Hook.pre_recovery_replay() => :pre_replay,
      Hook.post_recovery_replay() => :post_replay
    })
  end

  defp opt_in(hub_id, opts) do
    auto_recovery =
      Keyword.merge(
        [reconcile_grace_ms: @no_timer_grace_ms, reconcile_interval_ms: @interval_ms],
        opts
      )

    [
      hub_id: hub_id,
      auto_recovery: auto_recovery,
      hooks: default_hooks(),
      synchronization_strategy: @sync_strategy
    ]
  end

  defp cspec(id), do: %{id: id, start: {Test.Helper.TestServer, :start_link, [%{name: id}]}}

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  describe "parse_config/1" do
    test "false / true / keyword shapes" do
      assert {:ok,
              %{
                enabled?: false,
                reconcile_grace_ms: 30_000,
                reconcile_interval_ms: 15_000,
                stopped_row_ttl_ms: 86_400_000
              }} = Recovery.parse_config(false)

      assert {:ok, %{enabled?: true, reconcile_grace_ms: 30_000}} = Recovery.parse_config(true)

      assert {:ok,
              %{
                enabled?: true,
                reconcile_grace_ms: 60_000,
                reconcile_interval_ms: 30_000,
                stopped_row_ttl_ms: 604_800_000
              }} =
               Recovery.parse_config(
                 reconcile_grace_ms: 60_000,
                 reconcile_interval_ms: 30_000,
                 stopped_row_ttl_ms: 604_800_000
               )
    end

    test "rejects out-of-range values and unknown shapes" do
      assert {:error, {:invalid_auto_recovery, :reconcile_grace_ms_out_of_range}} =
               Recovery.parse_config(reconcile_grace_ms: 100)

      assert {:error, {:invalid_auto_recovery, :reconcile_interval_ms_out_of_range}} =
               Recovery.parse_config(reconcile_interval_ms: 10_000_000)

      assert {:error, {:invalid_auto_recovery, :stopped_row_ttl_ms_out_of_range}} =
               Recovery.parse_config(stopped_row_ttl_ms: 99_999_999_999)

      assert {:error, :invalid_auto_recovery} = Recovery.parse_config(:bad)
    end

    test "accepts the deprecated marker-era keys with a warning and ignores them" do
      for key <- [:marker_path, :replay_timeout_ms, :recovery_timeout_ms] do
        log =
          capture_log(fn ->
            assert {:ok, config} = Recovery.parse_config([{key, "whatever"}])
            assert config.enabled?
            assert config.reconcile_grace_ms == 30_000
            refute Map.has_key?(config, key)
          end)

        assert log =~ Atom.to_string(key)
        assert log =~ "deprecated"
        assert log =~ "future release"
      end
    end

    test "a deprecated key still starts the hub" do
      hub_id = SetupHelper.unique_id(:rec_deprecated_key)

      log =
        capture_log(fn ->
          {^hub_id, _pid} =
            SetupHelper.start_hub!(
              hub_id: hub_id,
              auto_recovery: [marker_path: "/srv/hub/cluster.healthy"]
            )

          assert ProcessHub.is_alive?(hub_id)
        end)

      assert log =~ ":marker_path"
    end
  end

  # ---------------------------------------------------------------------------
  # Deprecated marker-era operator API
  # ---------------------------------------------------------------------------

  describe "deprecated operator API" do
    # Called through apply/3 so the intentional @deprecated attribute does not
    # emit a compile warning for the suite.
    defp deprecated(fun, args), do: apply(Recovery, fun, args)

    test "prepare_recovery/1 is a no-op that warns" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:rec_prep))

      log = capture_log(fn -> assert deprecated(:prepare_recovery, [hub_id]) == :ok end)

      assert log =~ "prepare_recovery/1"
      assert log =~ "deprecated"
      assert log =~ "future release"
    end

    test "prepare_recovery_cluster/1 still reports the hub members" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:rec_prep_cluster))

      capture_log(fn ->
        assert {:ok, members} = deprecated(:prepare_recovery_cluster, [hub_id])
        assert node() in members
      end)

      capture_log(fn ->
        assert deprecated(:prepare_recovery_cluster, [:no_such_hub]) == {:error, :not_alive}
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Back-compat: the default configuration
  # ---------------------------------------------------------------------------

  describe "auto_recovery: false (default)" do
    test "recovery_state is :normal, await_normal is :ok, and nothing reconciles",
         %{dets: dets} do
      {hub_id, _pid} =
        SetupHelper.start_hub!(
          hub_id: SetupHelper.unique_id(:rec_default),
          registry_backend: {:durable_ets, path: dets},
          hooks: default_hooks()
        )

      assert Recovery.recovery_state(hub_id) == :normal
      assert Recovery.await_normal(hub_id, 100) == :ok

      # Even asked directly, a disabled hub runs no round.
      reconcile_now(hub_id)
      refute_receive {:sc, _}, 200
      refute_receive {:round, _}, 100
      refute_receive {:pre_replay, _}, 100

      assert Recovery.recovery_state(:no_such_hub) == :normal
      assert Recovery.await_normal(:no_such_hub, 50) == :ok
    end

    test "durable rows are replayed into the live registry as before", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_default_replay)
      conf = [hub_id: hub_id, registry_backend: {:durable_ets, path: dets}]
      {^hub_id, pid} = SetupHelper.start_hub!(conf)

      ProcessRegistry.insert(hub_id, cspec(:kept), [{node(), self()}])

      {^hub_id, _pid} = SetupHelper.restart_hub!(hub_id, pid, conf)
      assert ProcessRegistry.entry_exists?(hub_id, :kept)
    end
  end

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  describe "opt-in lifecycle" do
    test "starts :recovering and settles to :normal after the first round", %{dets: dets} do
      {hub_id, _pid} =
        SetupHelper.start_hub!(
          opt_in(SetupHelper.unique_id(:rec_settle), []) ++
            [registry_backend: {:durable_ets, path: dets}]
        )

      assert Recovery.recovery_state(hub_id) == :recovering
      reconcile_now(hub_id)

      assert_receive {:sc,
                      %{
                        hub_id: ^hub_id,
                        from: :recovering,
                        to: :normal,
                        reason: :reconcile_complete
                      }},
                     5_000

      assert Recovery.recovery_state(hub_id) == :normal
      assert Recovery.await_normal(hub_id, 5_000) == :ok

      # Terminal: no further transitions.
      refute_receive {:sc, _}, 200
    end

    test "a node alone still reaches :normal on the :ets backend" do
      {hub_id, _pid} = SetupHelper.start_hub!(opt_in(SetupHelper.unique_id(:rec_alone), []))

      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 5_000) == :ok
      assert_receive {:round, %{measurements: %{candidates: 0, orphans: 0, started: 0}}}, 5_000
    end

    test "await_normal below the grace window times out", %{dets: dets} do
      {hub_id, _pid} =
        SetupHelper.start_hub!(
          opt_in(SetupHelper.unique_id(:rec_await_timeout), []) ++
            [registry_backend: {:durable_ets, path: dets}]
        )

      assert Recovery.await_normal(hub_id, 200) == {:error, :timeout}
      assert Recovery.recovery_state(hub_id) == :recovering
    end
  end

  # ---------------------------------------------------------------------------
  # Hooks and telemetry
  # ---------------------------------------------------------------------------

  describe "hooks" do
    test "pre/post replay fire once, bracketing the first round", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_hooks)
      conf = opt_in(hub_id, []) ++ [registry_backend: {:durable_ets, path: dets}]
      {^hub_id, pid} = SetupHelper.start_hub!(conf)
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_children(hub_id, [cspec(:hooked)], awaitable: true)
               |> ProcessHub.await()

      # After the restart the child is a durable-only candidate, so the first
      # round of the new coordinator issues a start.
      {^hub_id, _pid} = SetupHelper.restart_hub!(hub_id, pid, conf)
      flush_hooks()
      reconcile_now(hub_id)

      assert_receive {:pre_replay, %{hub_id: ^hub_id, child_count: 1}}, 10_000
      assert_receive {:post_replay, %{hub_id: ^hub_id, child_count: 1, succeeded: 1}}, 10_000

      # Subsequent rounds are per-round telemetry only.
      assert_receive {:round, %{first_round: false}}, 10_000
      refute_receive {:pre_replay, _}, 100
      refute_receive {:post_replay, _}, 100
    end

    test "a quiet round is still reported" do
      {hub_id, _pid} = SetupHelper.start_hub!(opt_in(SetupHelper.unique_id(:rec_quiet), []))
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 5_000) == :ok

      # A round that finds nothing still reports, so a silent reconcile stays
      # distinguishable from a stalled one. That later rounds keep reporting is
      # covered by the two-round test, which is already paying the rate limit.
      assert_receive {:round, %{first_round: true, measurements: %{orphans: 0, started: 0}}},
                     5_000
    end
  end

  # ---------------------------------------------------------------------------
  # Orphan arithmetic
  # ---------------------------------------------------------------------------

  describe "orphan reconcile" do
    test "a cold boot restores every durable candidate exactly once", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_cold_boot)
      conf = opt_in(hub_id, []) ++ [registry_backend: {:durable_ets, path: dets}]
      {^hub_id, pid} = SetupHelper.start_hub!(conf)
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok

      specs = Enum.map([:cb_a, :cb_b, :cb_c], &cspec/1)

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_children(hub_id, specs, awaitable: true) |> ProcessHub.await()

      assert map_size(ProcessRegistry.dump(hub_id)) == 3

      {^hub_id, _pid} = SetupHelper.restart_hub!(hub_id, pid, conf)

      # The live registry starts empty: durable rows reach the cluster through
      # the reconcile, never through the backend open.
      assert ProcessRegistry.dump(hub_id) == %{}

      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok

      assert_receive {:round, %{first_round: true, measurements: %{candidates: 3, started: 3}}},
                     10_000

      assert Test.Helper.Common.eventually(fn -> map_size(ProcessRegistry.dump(hub_id)) == 3 end)

      for id <- [:cb_a, :cb_b, :cb_c] do
        assert is_pid(ProcessHub.get_pid(hub_id, id))
      end
    end

    test "a child stopped before the restart is not resurrected", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_stopped)
      conf = opt_in(hub_id, []) ++ [registry_backend: {:durable_ets, path: dets}]
      {^hub_id, pid} = SetupHelper.start_hub!(conf)
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok

      specs = Enum.map([:st_keep, :st_stop], &cspec/1)

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_children(hub_id, specs, awaitable: true) |> ProcessHub.await()

      assert %ProcessHub.StopResult{status: :ok} =
               ProcessHub.stop_children(hub_id, [:st_stop], awaitable: true) |> ProcessHub.await()

      assert %{lifecycle: :stopped} =
               ProcessRegistry.lookup(hub_id, :st_stop,
                 with_metadata: true,
                 include_empty: true
               )
               |> elem(2)
               |> Row.meta()

      {^hub_id, _pid} = SetupHelper.restart_hub!(hub_id, pid, conf)
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok

      assert_receive {:round, %{first_round: true, measurements: %{candidates: 2, started: 1}}},
                     10_000

      assert Test.Helper.Common.eventually(fn -> is_pid(ProcessHub.get_pid(hub_id, :st_keep)) end)
      assert ProcessHub.get_pid(hub_id, :st_stop) == nil
    end

    test "a registered but unbound child waits for a second round", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_two_rounds)

      {^hub_id, _pid} =
        SetupHelper.start_hub!(
          opt_in(hub_id, []) ++ [registry_backend: {:durable_ets, path: dets}]
        )

      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok
      # Drain the first round's report before seeding.
      assert_receive {:round, %{first_round: true}}, 10_000

      # A registered row with no observed pid: the mid-migration shape.
      ProcessRegistry.insert(hub_id, cspec(:mid_migration), [])

      # Two further rounds, spaced by the rate limit.
      assert_receive {:round, %{measurements: %{orphans: 0, skipped_pending: 1, started: 0}}},
                     @interval_ms * 3

      assert_receive {:round, %{measurements: %{orphans: 1, started: 1}}}, @interval_ms * 3
    end

    test "the :ets backend has no candidates and starts nothing" do
      {hub_id, _pid} = SetupHelper.start_hub!(opt_in(SetupHelper.unique_id(:rec_ets), []))
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 5_000) == :ok

      assert_receive {:round, %{measurements: %{candidates: 0, started: 0}}}, 5_000
      assert ProcessRegistry.dump(hub_id) == %{}
    end
  end
end
