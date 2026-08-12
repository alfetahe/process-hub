defmodule Test.Service.ProcessRegistryEpochTest do
  @moduledoc """
  Row bookkeeping under the reserved `:__process_hub__` key: the per-child epoch,
  the `:running`/`:stopped` lifecycle, and the absolute stopped-row expiry.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.ProcessRegistry.Row
  alias ProcessHub.Service.Recovery
  alias ProcessHub.Service.Storage
  alias ProcessHub.Worker.Janitor
  alias Test.Helper.Common
  alias Test.Helper.SetupHelper

  @stopped_row_ttl_ms 86_400_000

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "ph_epoch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, %{tmp_dir: tmp_dir}}
  end

  defp spec(id), do: %{id: id, start: {:m, :f, []}}

  defp row(hub_id, id),
    do: ProcessRegistry.lookup(hub_id, id, with_metadata: true, include_empty: true)

  defp hub_meta(hub_id, id) do
    {_cs, _nodes, meta} = row(hub_id, id)
    Row.meta(meta)
  end

  defp expiry(hub_id, id) do
    case Storage.match(hub_id, {id, :_, :"$1"}) do
      [{expire}] -> expire
      _ -> nil
    end
  end

  # --- 8.1 epoch --------------------------------------------------------------

  describe "epoch" do
    test "starts at 1 and increments on every authoring write" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:epoch_inc))

      ProcessRegistry.insert(hub_id, spec(:cid_a), [{node(), self()}])
      assert %{epoch: 1, lifecycle: :running, changed_by: node_name} = hub_meta(hub_id, :cid_a)
      assert node_name == node()

      for _ <- 1..2 do
        :ok =
          ProcessRegistry.update(hub_id, :cid_a, fn cs, np, meta ->
            {cs, np, Map.put(meta, :touched, true)}
          end)
      end

      assert %{epoch: 3} = hub_meta(hub_id, :cid_a)
    end

    test "a caller cannot forge the reserved key" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:epoch_forge))

      log =
        capture_log(fn ->
          ProcessRegistry.insert(hub_id, spec(:cid_forge), [{node(), self()}],
            metadata: %{tag: "t", __process_hub__: %{epoch: 9_999}}
          )
        end)

      assert %{epoch: 1} = hub_meta(hub_id, :cid_forge)
      assert log =~ ":__process_hub__"
      assert log =~ "cid_forge"

      {_cs, _nodes, meta} = row(hub_id, :cid_forge)
      assert Common.caller_meta(meta) == %{tag: "t"}
    end

    test "a bulk write that changes nothing does not advance the epoch" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:epoch_idem))
      children = %{cid_b: {spec(:cid_b), [{node(), self()}], %{}}}

      ProcessRegistry.bulk_insert(hub_id, children)
      assert %{epoch: 1} = hub_meta(hub_id, :cid_b)

      ProcessRegistry.bulk_insert(hub_id, children)
      assert %{epoch: 1} = hub_meta(hub_id, :cid_b)
    end
  end

  # --- 8.4 lifecycle ----------------------------------------------------------

  describe "lifecycle" do
    test "a deliberate stop leaves a durable stopped row that survives re-open",
         %{tmp_dir: tmp_dir} do
      hub_id = SetupHelper.unique_id(:lifecycle_stop)
      path = Path.join(tmp_dir, "registry.dets")
      SetupHelper.start_hub!(hub_id: hub_id, registry_backend: {:durable_ets, path: path})

      ProcessRegistry.insert(hub_id, spec(:cid_s), [{node(), self()}])
      assert %{epoch: 1, lifecycle: :running} = hub_meta(hub_id, :cid_s)

      ProcessRegistry.bulk_delete(hub_id, [{:cid_s, [node()]}], on_empty: :stopped)

      assert {_cs, [], _meta} = row(hub_id, :cid_s)
      assert %{epoch: 2, lifecycle: :stopped, stopped_at: stopped_at} = hub_meta(hub_id, :cid_s)
      assert expiry(hub_id, :cid_s) == stopped_at + @stopped_row_ttl_ms

      :ok = ProcessHub.Initializer.stop(hub_id)

      {:ok, pid} =
        ProcessHub.Initializer.start_link(%ProcessHub{
          hub_id: hub_id,
          registry_backend: {:durable_ets, path: path}
        })

      :erlang.unlink(pid)
      assert %{lifecycle: :stopped, stopped_at: ^stopped_at} = hub_meta(hub_id, :cid_s)
    end

    test "starting the child again clears the stopped state and its expiry" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:lifecycle_restart))

      ProcessRegistry.insert(hub_id, spec(:cid_r), [{node(), self()}])
      ProcessRegistry.bulk_delete(hub_id, [{:cid_r, [node()]}], on_empty: :stopped)
      assert %{epoch: 2, lifecycle: :stopped} = hub_meta(hub_id, :cid_r)
      assert expiry(hub_id, :cid_r)

      # A stopped row is invisible to placement, so a restart is not "already started".
      assert ProcessRegistry.contains_children(hub_id, [:cid_r]) == []

      ProcessRegistry.bulk_insert(hub_id, %{cid_r: {spec(:cid_r), [{node(), self()}], %{}}})

      assert %{epoch: 3, lifecycle: :running} = meta = hub_meta(hub_id, :cid_r)
      refute Map.has_key?(meta, :stopped_at)
      refute expiry(hub_id, :cid_r)
    end

    test "a child the supervisor declines to restart leaves a stopped row" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:lifecycle_selfstop))

      child_spec = %{
        id: :cid_self,
        start: {Test.Helper.TestServer, :start_link, [%{name: :cid_self}]},
        restart: :temporary
      }

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_children(hub_id, [child_spec], awaitable: true)
               |> ProcessHub.await()

      assert %{lifecycle: :running} = hub_meta(hub_id, :cid_self)

      # A `:temporary` child that stops itself is not restarted, so the row must
      # not be left as a churn stub the reconcile would resurrect.
      :ok = GenServer.stop(ProcessHub.get_pid(hub_id, :cid_self), :normal)

      assert Common.eventually(fn -> Row.stopped?(elem(row(hub_id, :cid_self), 2)) end)
      assert {_cs, [], _meta} = row(hub_id, :cid_self)
      assert expiry(hub_id, :cid_self)
    end

    test "placement churn leaves a short-lived stub, not a stopped row" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:lifecycle_churn))

      ProcessRegistry.insert(hub_id, spec(:cid_c), [{node(), self()}])
      ProcessRegistry.bulk_delete(hub_id, [{:cid_c, [node()]}])

      assert %{lifecycle: :running} = hub_meta(hub_id, :cid_c)
      churn_expiry = expiry(hub_id, :cid_c)
      assert churn_expiry
      assert churn_expiry < System.system_time(:millisecond) + 60_000
    end
  end

  # --- 8.5 expiry -------------------------------------------------------------

  describe "stopped-row expiry" do
    test "the deadline is stable across repeated sync re-writes" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:expiry_stable))

      ProcessRegistry.insert(hub_id, spec(:cid_e), [{node(), self()}])
      ProcessRegistry.bulk_delete(hub_id, [{:cid_e, [node()]}], on_empty: :stopped)

      %{stopped_at: stopped_at} = hub_meta(hub_id, :cid_e)
      deadline = stopped_at + @stopped_row_ttl_ms
      assert expiry(hub_id, :cid_e) == deadline

      # 20 merge-style re-writes adopting the same row verbatim.
      {cs, nodes, meta} = row(hub_id, :cid_e)

      for _ <- 1..20 do
        ProcessRegistry.insert(hub_id, cs, nodes, metadata: meta, adopt: true)
      end

      assert expiry(hub_id, :cid_e) == deadline
      assert %{stopped_at: ^stopped_at} = hub_meta(hub_id, :cid_e)
    end

    test "an expired stopped row is swept from the durable file", %{tmp_dir: tmp_dir} do
      for {backend, name} <- [{:dets, "dets"}, {:durable_ets, "durable_ets"}] do
        hub_id = SetupHelper.unique_id(:"expiry_sweep_#{name}")
        path = Path.join(tmp_dir, "#{name}.dets")

        SetupHelper.start_hub!(
          hub_id: hub_id,
          registry_backend: {backend, path: path},
          auto_recovery: [stopped_row_ttl_ms: 60_000, reconcile_grace_ms: 600_000]
        )

        ProcessRegistry.insert(hub_id, spec(:cid_x), [{node(), self()}])
        ProcessRegistry.bulk_delete(hub_id, [{:cid_x, [node()]}], on_empty: :stopped)
        assert %{lifecycle: :stopped} = hub_meta(hub_id, :cid_x)

        # Age the row past its deadline by rewriting it with an elapsed stopped_at.
        {cs, nodes, meta} = row(hub_id, :cid_x)
        aged = Row.meta(meta) |> Map.put(:stopped_at, 0)

        ProcessRegistry.insert(hub_id, cs, nodes,
          metadata: Map.put(meta, :__process_hub__, aged),
          adopt: true
        )

        Janitor.purge_pending_registry(hub_id)

        assert row(hub_id, :cid_x) == nil, "#{name}: expired stopped row still in the registry"
        assert {:ok, rows} = Storage.read_durable(hub_id)

        refute Enum.any?(rows, fn {key, _value} -> key == :cid_x end),
               "#{name}: expired stopped row still on disk"
      end
    end

    test "an out-of-range stopped_row_ttl_ms fails init" do
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_auto_recovery, :stopped_row_ttl_ms_out_of_range}} =
               Recovery.parse_config(stopped_row_ttl_ms: 1_000)

      assert {:error, _} =
               ProcessHub.Initializer.start_link(%ProcessHub{
                 hub_id: SetupHelper.unique_id(:expiry_bad_ttl),
                 auto_recovery: [stopped_row_ttl_ms: 1_000]
               })
    end
  end
end
