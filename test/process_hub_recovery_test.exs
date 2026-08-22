defmodule Test.ProcessHubRecoveryTest do
  @moduledoc """
  Covers the opt-in declared-children lifecycle end to end: `:auto_recovery`
  config parsing, the two-state `:recovering → :normal` lifecycle, the reconcile
  hooks, and the orphan arithmetic (declared list − observed) driven through a
  real hub. Multi-node scenarios live in
  `test/process_hub_reconcile_multinode_test.exs`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.DeclaredChildren
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Recovery
  alias ProcessHub.Storage.RemoteManifest.LocalPath
  alias ProcessHub.Strategy.Synchronization.PubSub
  alias Test.Helper.SetupHelper

  # Rounds are triggered explicitly with `reconcile_now/1` rather than waited for,
  # so the grace window is set beyond any test's lifetime. Tests that assert the
  # *timer* path say so locally.
  @no_timer_grace_ms 600_000
  # The lowest interval the config accepts; only the tests that genuinely need
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
      {tag, _payload} when tag in [:sc, :round, :pre_replay, :post_replay, :parked] ->
        flush_hooks()
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
      Hook.post_recovery_replay() => :post_replay,
      Hook.declared_parked() => :parked
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

  defp durable_conf(hub_id, dets, recovery_opts \\ []) do
    opt_in(hub_id, recovery_opts) ++ [registry_backend: {:durable_ets, path: dets}]
  end

  defp cleanup_priv(hub_id), do: on_exit(fn -> File.rm_rf!("priv/process_hub/#{hub_id}") end)

  defp declared_ids(hub_id) do
    DeclaredChildren.declared_children(hub_id).children |> Enum.map(& &1.id) |> Enum.sort()
  end

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
                remote_manifest: nil
              }} = Recovery.parse_config(false)

      assert {:ok, %{enabled?: true, reconcile_grace_ms: 30_000}} = Recovery.parse_config(true)

      assert {:ok,
              %{
                enabled?: true,
                reconcile_grace_ms: 60_000,
                reconcile_interval_ms: 30_000,
                remote_manifest: {LocalPath, [path: "/tmp/manifests"]}
              }} =
               Recovery.parse_config(
                 reconcile_grace_ms: 60_000,
                 reconcile_interval_ms: 30_000,
                 remote_manifest: {LocalPath, path: "/tmp/manifests"}
               )
    end

    test "the grace floor is lower than the interval floor" do
      # The grace is a one-shot startup delay, so it may be short; the interval
      # is recurring and each round diffs the registry, so it keeps the 1 s floor.
      assert {:ok, %{reconcile_grace_ms: 50}} = Recovery.parse_config(reconcile_grace_ms: 50)

      assert {:error, {:invalid_auto_recovery, :reconcile_interval_ms_out_of_range}} =
               Recovery.parse_config(reconcile_interval_ms: 50)
    end

    test "rejects out-of-range values and unknown shapes" do
      assert {:error, {:invalid_auto_recovery, :reconcile_grace_ms_out_of_range}} =
               Recovery.parse_config(reconcile_grace_ms: 49)

      assert {:error, {:invalid_auto_recovery, :reconcile_interval_ms_out_of_range}} =
               Recovery.parse_config(reconcile_interval_ms: 10_000_000)

      assert {:error, :invalid_auto_recovery} = Recovery.parse_config(:bad)
    end

    test "rejects an unusable remote manifest configuration" do
      assert {:error,
              {:invalid_auto_recovery,
               {:remote_manifest, {:remote_manifest_module_missing, NoSuch.Adapter}}}} =
               Recovery.parse_config(remote_manifest: {NoSuch.Adapter, []})

      assert {:error,
              {:invalid_auto_recovery, {:remote_manifest, {:local_path_requires_path, _}}}} =
               Recovery.parse_config(remote_manifest: {LocalPath, []})

      assert {:error,
              {:invalid_auto_recovery, {:remote_manifest, :remote_manifest_invalid_shape}}} =
               Recovery.parse_config(remote_manifest: :bad)
    end

    test "accepts the deprecated keys with a warning and ignores them" do
      for key <- [:marker_path, :replay_timeout_ms, :recovery_timeout_ms, :stopped_row_ttl_ms] do
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
      cleanup_priv(hub_id)

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
  # Back-compat: the default configuration costs nothing
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

    test "no declared-list file is created and durable starts are refused",
         %{dets: dets, tmp_dir: tmp_dir} do
      {hub_id, _pid} =
        SetupHelper.start_hub!(
          hub_id: SetupHelper.unique_id(:rec_zero_cost),
          registry_backend: {:durable_ets, path: dets}
        )

      assert {:error, :durable_requires_auto_recovery} =
               ProcessHub.start_child(hub_id, cspec(:zc_child), durable: true)

      assert DeclaredChildren.declared_children(hub_id) == %{version: 0, children: []}

      refute Path.join(tmp_dir, "registry.declared.dets") |> File.exists?()
      assert ProcessHub.get_pid(hub_id, :zc_child) == nil
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
        SetupHelper.start_hub!(durable_conf(SetupHelper.unique_id(:rec_settle), dets))

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
      hub_id = SetupHelper.unique_id(:rec_alone)
      cleanup_priv(hub_id)
      {^hub_id, _pid} = SetupHelper.start_hub!(opt_in(hub_id, []))

      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 5_000) == :ok
      assert_receive {:round, %{measurements: %{candidates: 0, orphans: 0, started: 0}}}, 5_000
    end

    test "await_normal below the grace window times out", %{dets: dets} do
      {hub_id, _pid} =
        SetupHelper.start_hub!(durable_conf(SetupHelper.unique_id(:rec_await_timeout), dets))

      assert Recovery.await_normal(hub_id, 200) == {:error, :timeout}
      assert Recovery.recovery_state(hub_id) == :recovering
    end
  end

  # ---------------------------------------------------------------------------
  # Declared list commands
  # ---------------------------------------------------------------------------

  describe "declared list" do
    test "start adds, stop removes, versions bump per mutation", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_declare)

      {^hub_id, _pid} = SetupHelper.start_hub!(durable_conf(hub_id, dets))

      assert DeclaredChildren.declared_children(hub_id) == %{version: 0, children: []}

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_children(hub_id, [cspec(:dcl_a), cspec(:dcl_b)],
                 awaitable: true,
                 durable: true
               )
               |> ProcessHub.await()

      assert %{version: 1} = DeclaredChildren.declared_children(hub_id)
      assert declared_ids(hub_id) == [:dcl_a, :dcl_b]

      assert %ProcessHub.StopResult{status: :ok} =
               ProcessHub.stop_children(hub_id, [:dcl_a], awaitable: true) |> ProcessHub.await()

      assert %{version: 2} = DeclaredChildren.declared_children(hub_id)
      assert declared_ids(hub_id) == [:dcl_b]

      # The stop removed the row entirely — no tombstone remains.
      assert ProcessRegistry.lookup(hub_id, :dcl_a, include_empty: true) == nil

      # Stopping a non-durable id does not touch the list.
      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_child(hub_id, cspec(:plain), awaitable: true)
               |> ProcessHub.await()

      assert %ProcessHub.StopResult{status: :ok} =
               ProcessHub.stop_children(hub_id, [:plain], awaitable: true) |> ProcessHub.await()

      assert %{version: 2} = DeclaredChildren.declared_children(hub_id)
    end

    test "concurrent durable starts share one sync and every entry survives a restart",
         %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_concurrent)
      {^hub_id, pid} = SetupHelper.start_hub!(durable_conf(hub_id, dets))
      ids = Enum.map(1..12, &:"conc_child_#{&1}")

      ids
      |> Task.async_stream(
        fn id ->
          ProcessHub.start_child(hub_id, cspec(id), awaitable: true, durable: true)
          |> ProcessHub.await()
        end,
        max_concurrency: 12
      )
      |> Enum.each(fn {:ok, result} -> assert %ProcessHub.StartResult{status: :ok} = result end)

      assert declared_ids(hub_id) == Enum.sort(ids)

      {^hub_id, _pid} = SetupHelper.restart_hub!(hub_id, pid, durable_conf(hub_id, dets))
      assert declared_ids(hub_id) == Enum.sort(ids)
    end

    test "durable requires a restartable restart type", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_permanent)

      {^hub_id, _pid} = SetupHelper.start_hub!(durable_conf(hub_id, dets))

      temporary = Map.put(cspec(:temporary_child), :restart, :temporary)

      assert {:error, :durable_requires_restartable} =
               ProcessHub.start_child(hub_id, temporary, durable: true)

      assert DeclaredChildren.declared_children(hub_id) == %{version: 0, children: []}
      assert ProcessHub.get_pid(hub_id, :temporary_child) == nil

      # `:transient`, an explicit `:permanent`, and the default all pass: a
      # normal exit of a transient durable child keeps its declared entry, and
      # the reconcile restarts it — the list stays authoritative.
      transient = Map.put(cspec(:transient_child), :restart, :transient)

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_child(hub_id, transient, awaitable: true, durable: true)
               |> ProcessHub.await()

      permanent = Map.put(cspec(:perm_child), :restart, :permanent)

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_child(hub_id, permanent, awaitable: true, durable: true)
               |> ProcessHub.await()

      assert declared_ids(hub_id) == [:perm_child, :transient_child]
    end

    test "an unreachable leader refuses durable commands but not plain ones", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_no_leader)

      {^hub_id, _pid} = SetupHelper.start_hub!(durable_conf(hub_id, dets))

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_child(hub_id, cspec(:nl_a), awaitable: true, durable: true)
               |> ProcessHub.await()

      # With elector down, leadership falls back to the lowest hub member; an
      # unreachable node that sorts below every real name becomes the leader.
      Application.stop(:elector)
      on_exit(fn -> DeclaredChildren.ensure_election() end)

      hub = ProcessHub.Coordinator.get_hub(hub_id)

      ProcessHub.Service.Storage.insert(
        hub.storage.misc,
        ProcessHub.Constant.StorageKey.hn(),
        [:aaa@nowhere, node()]
      )

      assert {:error, :no_leader} =
               ProcessHub.start_child(hub_id, cspec(:nl_b), durable: true)

      # A declared child cannot be stopped without the leader...
      assert {:error, :no_leader} = ProcessHub.stop_child(hub_id, :nl_a)
      assert declared_ids(hub_id) == [:nl_a]

      # ...but an undeclared child can.
      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_child(hub_id, cspec(:nl_plain), awaitable: true)
               |> ProcessHub.await()

      assert %ProcessHub.StopResult{status: :ok} =
               ProcessHub.stop_children(hub_id, [:nl_plain], awaitable: true)
               |> ProcessHub.await()
    end
  end

  # ---------------------------------------------------------------------------
  # Hooks and telemetry
  # ---------------------------------------------------------------------------

  describe "hooks" do
    test "pre/post replay fire once, bracketing the first round", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_hooks)
      conf = durable_conf(hub_id, dets)
      {^hub_id, pid} = SetupHelper.start_hub!(conf)
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_children(hub_id, [cspec(:hooked)], awaitable: true, durable: true)
               |> ProcessHub.await()

      # After the restart the child is a declared-only candidate, so the first
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
      hub_id = SetupHelper.unique_id(:rec_quiet)
      cleanup_priv(hub_id)
      {^hub_id, _pid} = SetupHelper.start_hub!(opt_in(hub_id, []))
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 5_000) == :ok

      # A round that finds nothing still reports, so a silent reconcile stays
      # distinguishable from a stalled one.
      assert_receive {:round, %{first_round: true, measurements: %{orphans: 0, started: 0}}},
                     5_000
    end
  end

  # ---------------------------------------------------------------------------
  # Orphan arithmetic
  # ---------------------------------------------------------------------------

  describe "orphan reconcile" do
    test "a cold boot restores every declared child exactly once", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_cold_boot)
      conf = durable_conf(hub_id, dets)
      {^hub_id, pid} = SetupHelper.start_hub!(conf)
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok

      specs = Enum.map([:cb_a, :cb_b, :cb_c], &cspec/1)

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_children(hub_id, specs, awaitable: true, durable: true)
               |> ProcessHub.await()

      assert map_size(ProcessRegistry.dump(hub_id)) == 3

      {^hub_id, _pid} = SetupHelper.restart_hub!(hub_id, pid, conf)

      # The live registry starts empty: restoration flows through the reconcile,
      # never through the backend open.
      assert ProcessRegistry.dump(hub_id) == %{}
      assert declared_ids(hub_id) == [:cb_a, :cb_b, :cb_c]

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
      conf = durable_conf(hub_id, dets)
      {^hub_id, pid} = SetupHelper.start_hub!(conf)
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok

      specs = Enum.map([:st_keep, :st_stop], &cspec/1)

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_children(hub_id, specs, awaitable: true, durable: true)
               |> ProcessHub.await()

      assert %ProcessHub.StopResult{status: :ok} =
               ProcessHub.stop_children(hub_id, [:st_stop], awaitable: true) |> ProcessHub.await()

      # Stop memory is list absence, not a row.
      assert ProcessRegistry.lookup(hub_id, :st_stop, include_empty: true) == nil
      assert declared_ids(hub_id) == [:st_keep]

      {^hub_id, _pid} = SetupHelper.restart_hub!(hub_id, pid, conf)
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok

      assert_receive {:round, %{first_round: true, measurements: %{candidates: 1, started: 1}}},
                     10_000

      assert Test.Helper.Common.eventually(fn -> is_pid(ProcessHub.get_pid(hub_id, :st_keep)) end)
      assert ProcessHub.get_pid(hub_id, :st_stop) == nil
    end

    test "a running child whose declared entry is gone is stopped", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_undeclared)

      {^hub_id, _pid} = SetupHelper.start_hub!(durable_conf(hub_id, dets))

      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok
      assert_receive {:round, %{first_round: true}}, 10_000

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_child(hub_id, cspec(:und_x), awaitable: true, durable: true)
               |> ProcessHub.await()

      assert is_pid(ProcessHub.get_pid(hub_id, :und_x))

      # A stop that crashed between list removal and terminate leaves exactly
      # this state: running but undeclared.
      assert :ok = GenServer.call(hub_id, {:declared_mutate, {:remove, [:und_x]}})

      assert_receive {:round, %{measurements: %{stopped_undeclared: 1}}}, @interval_ms * 3

      assert Test.Helper.Common.eventually(fn ->
               ProcessHub.get_pid(hub_id, :und_x) == nil
             end)
    end

    test "a registered but unbound declared child waits for a second round", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_two_rounds)

      {^hub_id, _pid} = SetupHelper.start_hub!(durable_conf(hub_id, dets))

      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok
      # Drain the first round's report before seeding.
      assert_receive {:round, %{first_round: true}}, 10_000

      # Declared, with a registered row that has no observed pid: the
      # mid-migration shape.
      assert :ok = GenServer.call(hub_id, {:declared_mutate, {:add, [cspec(:mid_migration)]}})
      ProcessRegistry.insert(hub_id, cspec(:mid_migration), [])

      # Two further rounds, spaced by the rate limit.
      assert_receive {:round, %{measurements: %{orphans: 0, skipped_pending: 1, started: 0}}},
                     @interval_ms * 3

      assert_receive {:round, %{measurements: %{orphans: 1, started: 1}}}, @interval_ms * 3
    end

    test "a stale durable row observed nowhere is removed after two rounds", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_ghost)

      {^hub_id, _pid} = SetupHelper.start_hub!(durable_conf(hub_id, dets))

      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok
      assert_receive {:round, %{first_round: true}}, 10_000

      # The shape a stale rejoining peer leaves behind: a row marked durable,
      # bound nowhere, for a child the declared list no longer holds.
      ProcessRegistry.bulk_insert(hub_id, %{ghost: {cspec(:ghost), [], %{}}}, durable: true)

      assert_receive {:round, %{measurements: %{removed_stale: 0}}}, @interval_ms * 3
      assert_receive {:round, %{measurements: %{removed_stale: 1}}}, @interval_ms * 3

      refute ProcessRegistry.entry_exists?(hub_id, :ghost)
      assert ProcessHub.get_pid(hub_id, :ghost) == nil
    end

    test "an empty declared list has no candidates and starts nothing" do
      hub_id = SetupHelper.unique_id(:rec_ets)
      cleanup_priv(hub_id)
      {^hub_id, _pid} = SetupHelper.start_hub!(opt_in(hub_id, []))
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 5_000) == :ok

      assert_receive {:round, %{measurements: %{candidates: 0, started: 0}}}, 5_000
      assert ProcessRegistry.dump(hub_id) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Seed, park, and operator clear
  # ---------------------------------------------------------------------------

  describe "seed and park" do
    test "first enablement seeds version 1 from existing durable rows", %{dets: dets} do
      hub_id = SetupHelper.unique_id(:rec_seed)
      plain_conf = [hub_id: hub_id, registry_backend: {:durable_ets, path: dets}]
      {^hub_id, pid} = SetupHelper.start_hub!(plain_conf)

      # Rows written by a hub that never had the feature on.
      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_children(hub_id, [cspec(:seed_a), cspec(:seed_b)],
                 awaitable: true
               )
               |> ProcessHub.await()

      conf = durable_conf(hub_id, dets)
      {^hub_id, pid} = SetupHelper.restart_hub!(hub_id, pid, conf)

      assert %{version: 1} = DeclaredChildren.declared_children(hub_id)
      assert declared_ids(hub_id) == [:seed_a, :seed_b]

      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok

      assert Test.Helper.Common.eventually(fn ->
               is_pid(ProcessHub.get_pid(hub_id, :seed_a)) and
                 is_pid(ProcessHub.get_pid(hub_id, :seed_b))
             end)

      # Subsequent boots do not re-seed: the version lineage continues.
      {^hub_id, _pid} = SetupHelper.restart_hub!(hub_id, pid, conf)
      assert %{version: 1} = DeclaredChildren.declared_children(hub_id)
    end

    test "a lost list with a seeded marker parks the reconcile", %{dets: dets, tmp_dir: tmp_dir} do
      hub_id = SetupHelper.unique_id(:rec_park)
      conf = durable_conf(hub_id, dets)
      {^hub_id, _pid} = SetupHelper.start_hub!(conf)
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_child(hub_id, cspec(:park_a), awaitable: true, durable: true)
               |> ProcessHub.await()

      :ok = ProcessHub.Initializer.stop(hub_id)

      # The list file is lost; the seeded marker beside it survives.
      declared_file = Path.join(tmp_dir, "registry.declared.dets")
      assert File.exists?(declared_file)
      assert File.exists?(declared_file <> ".seeded")
      File.rm!(declared_file)

      # Drain the first incarnation's hook messages before the restart so the
      # parked report cannot be swallowed with them.
      flush_hooks()
      {:ok, new_pid} = ProcessHub.Initializer.start_link(SetupHelper.hub_struct(conf))
      :erlang.unlink(new_pid)

      assert_receive {:parked, %{hub_id: ^hub_id, reason: :local_list_lost}}, 5_000

      # The round runs but starts and stops nothing.
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok
      assert_receive {:round, %{measurements: %{candidates: 0, started: 0}}}, 5_000
      assert ProcessHub.get_pid(hub_id, :park_a) == nil

      # Mutations are refused while parked.
      assert {:error, :declared_list_parked} =
               ProcessHub.start_child(hub_id, cspec(:park_b), durable: true)

      # Only the explicit operator call clears the state.
      assert :ok = DeclaredChildren.clear(hub_id)
      assert DeclaredChildren.declared_children(hub_id).children == []

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_child(hub_id, cspec(:park_b), awaitable: true, durable: true)
               |> ProcessHub.await()

      assert declared_ids(hub_id) == [:park_b]
      :ok = ProcessHub.Initializer.stop(hub_id)
    end

    test "lost local disks restore the list from the remote manifest",
         %{dets: dets, tmp_dir: tmp_dir} do
      hub_id = SetupHelper.unique_id(:rec_remote)
      manifest_dir = Path.join(tmp_dir, "manifests")

      conf = durable_conf(hub_id, dets, remote_manifest: {LocalPath, path: manifest_dir})

      {^hub_id, _pid} = SetupHelper.start_hub!(conf)
      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_children(hub_id, [cspec(:rm_keep), cspec(:rm_stop)],
                 awaitable: true,
                 durable: true
               )
               |> ProcessHub.await()

      # The stop commits v2 locally; the async ship must land before the
      # "disks" are lost.
      assert %ProcessHub.StopResult{status: :ok} =
               ProcessHub.stop_children(hub_id, [:rm_stop], awaitable: true)
               |> ProcessHub.await()

      assert Test.Helper.Common.eventually(fn ->
               match?({:ok, {2, _}}, LocalPath.fetch(hub_id, path: manifest_dir))
             end)

      :ok = ProcessHub.Initializer.stop(hub_id)

      # Every cluster disk is lost: the registry, the list, and the marker.
      File.rm!(dets)
      File.rm!(Path.join(tmp_dir, "registry.declared.dets"))
      File.rm!(Path.join(tmp_dir, "registry.declared.dets.seeded"))

      {:ok, new_pid} = ProcessHub.Initializer.start_link(SetupHelper.hub_struct(conf))
      :erlang.unlink(new_pid)
      on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)

      assert %{version: 2} = DeclaredChildren.declared_children(hub_id)
      assert declared_ids(hub_id) == [:rm_keep]

      reconcile_now(hub_id)
      assert Recovery.await_normal(hub_id, 10_000) == :ok

      assert Test.Helper.Common.eventually(fn -> is_pid(ProcessHub.get_pid(hub_id, :rm_keep)) end)
      assert ProcessHub.get_pid(hub_id, :rm_stop) == nil
    end

    test "a stored list with a newer format marker refuses to open", %{
      dets: dets,
      tmp_dir: tmp_dir
    } do
      hub_id = SetupHelper.unique_id(:rec_format)
      conf = durable_conf(hub_id, dets)
      {^hub_id, pid} = SetupHelper.start_hub!(conf)
      :ok = ProcessHub.Initializer.stop(hub_id)
      _ = pid

      declared_file = Path.join(tmp_dir, "registry.declared.dets")
      # DETS records the table name in the file, so the probe must reuse the
      # name the hub opens the list under.
      table = :"#{hub_id}_declared_list"
      {:ok, ^table} = :dets.open_file(table, file: to_charlist(declared_file), type: :set)

      :ok =
        :dets.insert(
          table,
          {:manifest, %{format: 99, version: 1, mutated_by: node(), entries: %{}}}
        )

      :ok = :dets.close(table)

      Process.flag(:trap_exit, true)

      capture_log(fn ->
        assert {:error, _} = ProcessHub.Initializer.start_link(SetupHelper.hub_struct(conf))
      end)
    end
  end
end
