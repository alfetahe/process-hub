defmodule Test.Service.DeclaredChildrenTest do
  @moduledoc """
  Unit coverage for the declared list's pure edges: version-based adoption with
  the deterministic tiebreak, leader resolution with the hub-member fallback,
  and the manifest blob codec. The command paths, seed, park, and remote
  restore run against real hubs in `test/process_hub_recovery_test.exs`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.DeclaredChildren
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.Storage.DurableEts
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Hub

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "ph_declared_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    hub_id = :"declared_unit_#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "declared.dets")
    {:ok, ref} = DurableEts.open(:"#{hub_id}_list", path: path)
    on_exit(fn -> DurableEts.close(ref) end)

    hub = %Hub{
      hub_id: hub_id,
      procs: %{event_queue: :no_queue, manifest_shipper: :no_shipper, task_sup: nil},
      storage: %{
        misc: :ets.new(hub_id, [:set, :public]),
        hook: :ets.new(hub_id, [:set, :public]),
        declared_backend: {DurableEts, ref},
        declared_path: path
      },
      recovery_config: %{
        enabled?: true,
        reconcile_grace_ms: 30_000,
        reconcile_interval_ms: 15_000,
        remote_manifest: nil
      }
    }

    {:ok, %{hub: hub, backend_ref: ref}}
  end

  defp manifest(version, mutated_by, ids) do
    %{
      format: DeclaredChildren.format(),
      version: version,
      mutated_by: mutated_by,
      entries: Map.new(ids, &{&1, %{id: &1, start: {:m, :f, []}}})
    }
  end

  defp persisted(ref), do: DurableEts.get(ref, :manifest)

  describe "adopt/2" do
    test "a higher version replaces the local copy wholesale and persists",
         %{hub: hub, backend_ref: ref} do
      :ok = DeclaredChildren.adopt(hub, manifest(3, :peer@host, [:a, :b]))

      assert %{version: 3, entries: entries} = DeclaredChildren.manifest(hub)
      assert Map.keys(entries) |> Enum.sort() == [:a, :b]
      assert %{version: 3} = persisted(ref)

      # A lower or equal-content version changes nothing.
      :ok = DeclaredChildren.adopt(hub, manifest(2, :peer@host, [:zzz]))
      assert %{version: 3} = DeclaredChildren.manifest(hub)
    end

    test "a version tie with differing content resolves to the lowest mutating node",
         %{hub: hub} do
      HookManager.register_handlers(hub.storage.hook, Hook.declared_tiebreak(), [
        Bag.recv_hook(:tiebreak, self())
      ])

      :ok = DeclaredChildren.adopt(hub, manifest(5, :mmm@host, [:kept_by_m]))

      # A higher-named mutator loses the tie; the local copy stands.
      log =
        capture_log(fn ->
          :ok = DeclaredChildren.adopt(hub, manifest(5, :zzz@host, [:from_z]))
        end)

      assert log =~ "mutated by mmm@host over zzz@host"
      assert %{mutated_by: :mmm@host} = DeclaredChildren.manifest(hub)

      assert_receive {:tiebreak,
                      %{version: 5, kept_mutated_by: :mmm@host, discarded_mutated_by: :zzz@host}}

      # A lower-named mutator wins it.
      log =
        capture_log(fn ->
          :ok = DeclaredChildren.adopt(hub, manifest(5, :aaa@host, [:from_a]))
        end)

      assert log =~ "mutated by aaa@host over mmm@host"
      assert %{mutated_by: :aaa@host, entries: entries} = DeclaredChildren.manifest(hub)
      assert Map.keys(entries) == [:from_a]

      assert_receive {:tiebreak,
                      %{version: 5, kept_mutated_by: :aaa@host, discarded_mutated_by: :mmm@host}}
    end

    test "an unsupported format is ignored", %{hub: hub} do
      :ok = DeclaredChildren.adopt(hub, manifest(1, :peer@host, [:a]))

      newer = %{manifest(9, :peer@host, [:b]) | format: DeclaredChildren.format() + 1}
      log = capture_log(fn -> :ok = DeclaredChildren.adopt(hub, newer) end)
      assert log =~ "unsupported format #{newer.format}"

      assert %{version: 1} = DeclaredChildren.manifest(hub)
    end
  end

  describe "leader/1" do
    test "falls back to the lowest hub member when elector cannot name a member",
         %{hub: hub} do
      Application.stop(:elector)
      on_exit(fn -> DeclaredChildren.ensure_election() end)

      Storage.insert(hub.storage.misc, StorageKey.hn(), [:aaa@nowhere, node()])
      assert DeclaredChildren.leader(hub) == :aaa@nowhere

      Storage.insert(hub.storage.misc, StorageKey.hn(), [node(), :zzz@nowhere])
      assert DeclaredChildren.leader(hub) == node()
    end

    test "uses the elector leader when it is a hub member", %{hub: hub} do
      DeclaredChildren.ensure_election()
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node(), :zzz@nowhere])

      assert DeclaredChildren.leader(hub) == node()
    end
  end

  describe "reads" do
    test "declared_children/1 answers empty for an unknown hub" do
      assert DeclaredChildren.declared_children(:no_such_hub) == %{version: 0, children: []}
    end

    test "parked?/1 reflects the misc flag", %{hub: hub} do
      refute DeclaredChildren.parked?(hub)
      Storage.insert(hub.storage.misc, StorageKey.dclp(), true)
      assert DeclaredChildren.parked?(hub)
    end
  end

  describe "manifest blob" do
    test "encode/decode round-trips through a remote fetch shape", %{hub: hub} do
      source = manifest(4, node(), [:x, :y])
      blob = ProcessHub.Storage.RemoteManifest.encode(source)
      assert is_binary(blob)

      # The boot path decodes exactly what an adapter returns; simulate it via
      # a LocalPath store/fetch cycle.
      dir = Path.dirname(hub.storage.declared_path)
      adapter_opts = [path: dir]
      :ok = ProcessHub.Storage.RemoteManifest.LocalPath.store(hub.hub_id, 4, blob, adapter_opts)

      assert {:ok, {4, ^blob}} =
               ProcessHub.Storage.RemoteManifest.LocalPath.fetch(hub.hub_id, adapter_opts)

      assert :erlang.binary_to_term(blob) == source
    end
  end
end
