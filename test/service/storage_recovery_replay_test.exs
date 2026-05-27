defmodule Test.Service.StorageRecoveryReplayTest do
  @moduledoc """
  Backend `recovery_replay` opt tests for Storage.Dets and
  Storage.DurableEts.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Service.Storage.Dets
  alias ProcessHub.Service.Storage.DurableEts

  defp tmp_dets_path(prefix) do
    base = Path.join([System.tmp_dir!(), "process_hub_recreplay_#{prefix}_#{System.unique_integer([:positive])}"])
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    Path.join(base, "registry.dets")
  end

  defp unique_hub(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  describe "Storage.Dets.open/2 — recovery_replay: false" do
    test "skips DETS-row replay but keeps writes durable across re-open" do
      hub_id = unique_hub(:dets_replay_off)
      path = tmp_dets_path("dets_off")

      {:ok, ref} = Dets.open(hub_id, path: path)
      :ok = Dets.insert(ref, :a, 1)
      :ok = Dets.insert(ref, :b, 2)
      :ok = Dets.insert(ref, :c, 3)
      Dets.close(ref)

      {:ok, ref} = Dets.open(hub_id, path: path, recovery_replay: false)
      assert Dets.export_all(ref) == []
      :ok = Dets.insert(ref, :k, :v)
      Dets.close(ref)

      {:ok, ref} = Dets.open(hub_id, path: path, recovery_replay: true)
      rows = Dets.export_all(ref) |> Enum.sort()
      assert Enum.member?(rows, {:k, :v})
      Dets.close(ref)
    end
  end

  describe "Storage.DurableEts.open/2 — recovery_replay: false" do
    test "ETS stays empty even when DETS contains rows" do
      hub_id = unique_hub(:durable_off)
      path = tmp_dets_path("durable_off")

      {:ok, ref} = DurableEts.open(hub_id, path: path)
      :ok = DurableEts.insert(ref, :a, 1)
      :ok = DurableEts.insert(ref, :b, 2)
      DurableEts.close(ref)

      {:ok, ref} = DurableEts.open(hub_id, path: path, recovery_replay: false)
      assert DurableEts.export_all(ref) == []
      :ok = DurableEts.insert(ref, :k, :v)
      assert {:k, :v} in DurableEts.export_all(ref)
      DurableEts.close(ref)
    end

    test "recovery_replay: true (default) replays DETS into ETS" do
      hub_id = unique_hub(:durable_on)
      path = tmp_dets_path("durable_on")

      {:ok, ref} = DurableEts.open(hub_id, path: path)
      :ok = DurableEts.insert(ref, :a, 1)
      :ok = DurableEts.insert(ref, :b, 2)
      DurableEts.close(ref)

      {:ok, ref} = DurableEts.open(hub_id, path: path)
      rows = DurableEts.export_all(ref) |> Enum.sort()
      assert rows == [{:a, 1}, {:b, 2}]
      DurableEts.close(ref)
    end
  end

  describe "telemetry — replayed metadata" do
    test "Storage.Dets backend_opened includes replayed: false" do
      hub_id = unique_hub(:dets_telemetry)
      path = tmp_dets_path("dets_telemetry")
      handler_id = make_ref()
      parent = self()

      :telemetry.attach(handler_id, [:process_hub, :registry, :backend_opened], fn _e, m, md, _ ->
        send(parent, {:opened, m, md})
      end, nil)

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, ref} = Dets.open(hub_id, path: path, recovery_replay: false)
      Dets.close(ref)

      assert_receive {:opened, _measurements, %{replayed: false}}, 500
    end

    test "Storage.DurableEts backend_opened includes replayed: true by default" do
      hub_id = unique_hub(:durable_telemetry)
      path = tmp_dets_path("durable_telemetry")
      handler_id = make_ref()
      parent = self()

      :telemetry.attach(handler_id, [:process_hub, :registry, :backend_opened], fn _e, m, md, _ ->
        send(parent, {:opened, m, md})
      end, nil)

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, ref} = DurableEts.open(hub_id, path: path)
      DurableEts.close(ref)

      assert_receive {:opened, _measurements, %{replayed: true}}, 500
    end
  end
end
