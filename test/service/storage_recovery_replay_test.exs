defmodule Test.Service.StorageRecoveryReplayTest do
  @moduledoc """
  Backend `recovery_replay` opt and the `read_durable/1` durable-medium read for
  Storage.Ets, Storage.Dets, and Storage.DurableEts.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.Storage.Dets
  alias ProcessHub.Service.Storage.DurableEts
  alias ProcessHub.Service.Storage.Ets

  defp tmp_dets_path(prefix) do
    base =
      Path.join([
        System.tmp_dir!(),
        "process_hub_recreplay_#{prefix}_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    Path.join(base, "registry.dets")
  end

  defp unique_hub(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp sorted_durable(rows), do: rows |> Enum.sort()

  describe "Storage.Dets.open/2 — recovery_replay: false" do
    test "hides pre-existing rows from reads while keeping them on disk" do
      hub_id = unique_hub(:dets_replay_off)
      path = tmp_dets_path("dets_off")

      {:ok, ref} = Dets.open(hub_id, path: path)
      :ok = Dets.insert(ref, :a, 1)
      :ok = Dets.insert(ref, :b, 2)
      :ok = Dets.insert(ref, :c, 3)
      Dets.close(ref)

      {:ok, ref} = Dets.open(hub_id, path: path, recovery_replay: false)

      # The live view is empty...
      assert Dets.export_all(ref) == []
      assert Dets.get(ref, :a) == nil
      refute Dets.exists?(ref, :a)
      assert Dets.match(ref, {:"$1", :"$2"}) == []

      # ...but the rows are still durable candidates.
      assert {:ok, rows} = Dets.read_durable(ref)
      assert sorted_durable(rows) == [{:a, 1}, {:b, 2}, {:c, 3}]

      # Writing a hidden key un-hides it; a fresh key is visible immediately.
      :ok = Dets.insert(ref, :a, 10)
      :ok = Dets.insert(ref, :k, :v)
      assert Dets.get(ref, :a) == 10
      assert sorted_durable(Dets.export_all(ref)) == [{:a, 10}, {:k, :v}]
      Dets.close(ref)

      {:ok, ref} = Dets.open(hub_id, path: path, recovery_replay: true)
      assert sorted_durable(Dets.export_all(ref)) == [{:a, 10}, {:b, 2}, {:c, 3}, {:k, :v}]
      Dets.close(ref)
    end

    test "removing a hidden key clears it from disk too" do
      hub_id = unique_hub(:dets_replay_rm)
      path = tmp_dets_path("dets_rm")

      {:ok, ref} = Dets.open(hub_id, path: path)
      :ok = Dets.insert(ref, :a, 1)
      Dets.close(ref)

      {:ok, ref} = Dets.open(hub_id, path: path, recovery_replay: false)
      :ok = Dets.remove(ref, :a)
      assert Dets.read_durable(ref) == {:ok, []}
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
      assert {:ok, rows} = DurableEts.read_durable(ref)
      assert sorted_durable(rows) == [{:a, 1}, {:b, 2}]

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

  describe "read_durable/1" do
    test "the ETS backend has no durable medium" do
      hub_id = unique_hub(:ets_durable)
      {:ok, ref} = Ets.open(hub_id, [])
      :ok = Ets.insert(ref, :a, 1)

      assert Ets.read_durable(ref) == {:ok, []}
      Ets.close(ref)
    end

    test "expired rows are excluded" do
      for {backend, prefix} <- [{Dets, "dets_exp"}, {DurableEts, "durable_exp"}] do
        hub_id = unique_hub(prefix)
        path = tmp_dets_path(prefix)

        {:ok, ref} = backend.open(hub_id, path: path)
        :ok = backend.insert(ref, :live, 1, [])
        :ok = backend.insert(ref, :dead, 2, expire_at: 0)

        assert {:ok, [{:live, 1}]} = backend.read_durable(ref)
        backend.close(ref)
      end
    end

    test "an unreadable durable medium is an error, not an empty set" do
      hub_id = unique_hub(:dets_unreadable)
      path = tmp_dets_path("dets_unreadable")

      {:ok, {table, _shadow} = ref} = Dets.open(hub_id, path: path)
      :ok = Dets.insert(ref, :a, 1)

      # Close the DETS handle out from under the ref: the fold now fails.
      :dets.close(table)

      assert {:error, _reason} = Dets.read_durable(ref)
    end

    test "dispatches through the registered backend for a running hub" do
      hub_id = unique_hub(:durable_dispatch)
      path = tmp_dets_path("durable_dispatch")

      {:ok, pid} =
        ProcessHub.Initializer.start_link(%ProcessHub{
          hub_id: hub_id,
          registry_backend: {:durable_ets, path: path}
        })

      :erlang.unlink(pid)
      on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)

      ProcessHub.Service.ProcessRegistry.insert(hub_id, %{id: :c1, start: {:m, :f, []}}, [
        {node(), self()}
      ])

      assert {:ok, rows} = Storage.read_durable(hub_id)
      assert Enum.any?(rows, fn {key, _value} -> key == :c1 end)
    end
  end
end
