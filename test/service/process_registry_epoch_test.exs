defmodule Test.Service.ProcessRegistryEpochTest do
  @moduledoc """
  Row bookkeeping under the reserved `:__process_hub__` key: the per-child epoch,
  the durable flag, and what a deliberate delete or placement churn leaves
  behind.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.ProcessRegistry.Row
  alias ProcessHub.Service.Storage
  alias Test.Helper.Common
  alias Test.Helper.SetupHelper

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

  # --- epoch ------------------------------------------------------------------

  describe "epoch" do
    test "starts at 1 and increments on every authoring write" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:epoch_inc))

      ProcessRegistry.insert(hub_id, spec(:cid_a), [{node(), self()}])
      assert %{epoch: 1, changed_by: node_name} = hub_meta(hub_id, :cid_a)
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

  # --- durable flag -----------------------------------------------------------

  describe "durable flag" do
    test "is stamped on registration and survives subsequent authored writes" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:durable_flag))

      ProcessRegistry.bulk_insert(hub_id, %{cid_d: {spec(:cid_d), [{node(), self()}], %{}}},
        durable: true
      )

      assert %{epoch: 1, durable: true} = hub_meta(hub_id, :cid_d)
      assert Row.durable?(elem(row(hub_id, :cid_d), 2))

      :ok =
        ProcessRegistry.update(hub_id, :cid_d, fn cs, np, meta ->
          {cs, np, Map.put(meta, :touched, true)}
        end)

      assert %{epoch: 2, durable: true} = hub_meta(hub_id, :cid_d)
    end

    test "a plain registration carries no flag" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:durable_plain))

      ProcessRegistry.insert(hub_id, spec(:cid_p), [{node(), self()}])

      meta = hub_meta(hub_id, :cid_p)
      refute Map.has_key?(meta, :durable)
      refute Row.durable?(elem(row(hub_id, :cid_p), 2))
    end
  end

  # --- deliberate delete and churn -------------------------------------------

  describe "row removal" do
    test "a deliberate stop removes the row from memory and disk", %{tmp_dir: tmp_dir} do
      hub_id = SetupHelper.unique_id(:delete_stop)
      path = Path.join(tmp_dir, "registry.dets")
      SetupHelper.start_hub!(hub_id: hub_id, registry_backend: {:durable_ets, path: path})

      ProcessRegistry.insert(hub_id, spec(:cid_s), [{node(), self()}])
      assert %{epoch: 1} = hub_meta(hub_id, :cid_s)

      ProcessRegistry.bulk_delete(hub_id, [{:cid_s, [node()]}], on_empty: :delete)

      assert row(hub_id, :cid_s) == nil

      assert {:ok, rows} = Storage.read_durable(hub_id)
      refute Enum.any?(rows, fn {key, _value} -> key == :cid_s end)
    end

    test "a delete that only removes one node's entry keeps the row" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:delete_partial))

      ProcessRegistry.insert(hub_id, spec(:cid_m), [{node(), self()}, {:other@host, self()}])
      ProcessRegistry.bulk_delete(hub_id, [{:cid_m, [node()]}], on_empty: :delete)

      assert {_cs, nodes, _meta} = row(hub_id, :cid_m)
      assert Keyword.keys(nodes) == [:other@host]
    end

    test "a child the supervisor declines to restart is removed" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:delete_selfstop))

      child_spec = %{
        id: :cid_self,
        start: {Test.Helper.TestServer, :start_link, [%{name: :cid_self}]},
        restart: :temporary
      }

      assert %ProcessHub.StartResult{status: :ok} =
               ProcessHub.start_children(hub_id, [child_spec], awaitable: true)
               |> ProcessHub.await()

      assert %{epoch: _} = hub_meta(hub_id, :cid_self)

      # A `:temporary` child that stops itself is not restarted; its restart
      # policy has decided the child is done, so the row goes away rather than
      # lingering as a stub.
      :ok = GenServer.stop(ProcessHub.get_pid(hub_id, :cid_self), :normal)

      assert Common.eventually(fn -> row(hub_id, :cid_self) == nil end)
    end

    test "placement churn leaves a short-lived stub, not a removal" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:delete_churn))

      ProcessRegistry.insert(hub_id, spec(:cid_c), [{node(), self()}])
      ProcessRegistry.bulk_delete(hub_id, [{:cid_c, [node()]}])

      assert {_cs, [], _meta} = row(hub_id, :cid_c)
      churn_expiry = expiry(hub_id, :cid_c)
      assert churn_expiry
      assert churn_expiry < System.system_time(:millisecond) + 60_000
    end

    test "a withdrawn observation keeps the row with no expiry" do
      {hub_id, _pid} = SetupHelper.start_hub!(hub_id: SetupHelper.unique_id(:delete_keep))

      ProcessRegistry.insert(hub_id, spec(:cid_k), [{node(), self()}])
      ProcessRegistry.bulk_delete(hub_id, [{:cid_k, [node()]}], on_empty: :keep)

      assert {_cs, [], _meta} = row(hub_id, :cid_k)
      refute expiry(hub_id, :cid_k)
    end
  end
end
