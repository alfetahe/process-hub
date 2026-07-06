defmodule Test.ProcessHub.Service.Storage.DurableEtsTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Service.Storage.DurableEts, as: Backend

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "ph_durable_ets_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    hub_id = :"durable_ets_test_#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "registry.dets")

    {:ok, %{hub_id: hub_id, path: path, tmp_dir: tmp_dir}}
  end

  describe "open/2" do
    test "creates the file at a custom path and an empty ETS table", %{
      hub_id: hub_id,
      path: path
    } do
      {:ok, {ets_tid, dets_table} = ref} = Backend.open(hub_id, path: path)

      assert is_reference(ets_tid) or is_atom(ets_tid)
      assert dets_table === hub_id
      assert File.exists?(path)
      assert :ets.info(ets_tid, :size) === 0

      Backend.close(ref)
    end

    test "uses the default priv path when no :path is given", %{hub_id: hub_id} do
      {:ok, ref} = Backend.open(hub_id, [])

      expected_dir =
        Path.join([File.cwd!(), "priv", "process_hub", Atom.to_string(hub_id)])

      expected_path = Path.join(expected_dir, "registry.dets")
      on_exit(fn -> File.rm_rf!(expected_dir) end)

      assert File.exists?(expected_path)
      Backend.close(ref)
    end

    test "replays existing DETS rows into ETS on open", %{hub_id: hub_id, path: path} do
      # Pre-populate a DETS file with a couple of rows.
      {:ok, _} =
        :dets.open_file(hub_id, file: to_charlist(path), repair: true, type: :set)

      :ok = :dets.insert(hub_id, {:replay_a, :v_a})
      :ok = :dets.insert(hub_id, {:replay_b, :v_b})
      :ok = :dets.close(hub_id)

      {:ok, {ets_tid, _} = ref} = Backend.open(hub_id, path: path)

      assert :ets.info(ets_tid, :size) === 2
      assert Backend.get(ref, :replay_a) === :v_a
      assert Backend.get(ref, :replay_b) === :v_b

      Backend.close(ref)
    end
  end

  describe "round-trip" do
    test "insert + get + remove + clear_all", %{hub_id: hub_id, path: path} do
      {:ok, ref} = Backend.open(hub_id, path: path)

      assert :ok = Backend.insert(ref, :k1, :v1)
      assert Backend.get(ref, :k1) === :v1
      assert Backend.exists?(ref, :k1) === true
      assert Backend.exists?(ref, :missing) === false

      assert :ok = Backend.remove(ref, :k1)
      assert Backend.get(ref, :k1) === nil
      assert Backend.exists?(ref, :k1) === false

      assert :ok = Backend.insert(ref, :k2, :v2)
      assert :ok = Backend.clear_all(ref)
      assert Backend.export_all(ref) === []

      Backend.close(ref)
    end

    test "export_all and foldl mirror tab2list and ets foldl shape", %{
      hub_id: hub_id,
      path: path
    } do
      {:ok, ref} = Backend.open(hub_id, path: path)

      assert :ok = Backend.insert(ref, :a, 1)
      assert :ok = Backend.insert(ref, :b, 2)

      all = Backend.export_all(ref) |> Enum.sort()
      assert all === [{:a, 1}, {:b, 2}]

      sum =
        Backend.foldl(ref, 0, fn
          {_k, v}, acc -> acc + v
          {_k, v, _expire}, acc -> acc + v
        end)

      assert sum === 3

      Backend.close(ref)
    end

    test "match returns a list of tuples", %{hub_id: hub_id, path: path} do
      {:ok, ref} = Backend.open(hub_id, path: path)

      assert :ok = Backend.insert(ref, :one, :alpha)
      assert :ok = Backend.insert(ref, :two, :beta)

      result = Backend.match(ref, {:"$1", :"$2"}) |> Enum.sort()
      assert result === [{:one, :alpha}, {:two, :beta}]

      Backend.close(ref)
    end
  end

  describe "ETS is the read source-of-truth" do
    test "reads do not consult DETS — confirmed via DETS-bypass write", %{
      hub_id: hub_id,
      path: path
    } do
      {:ok, {ets_tid, _dets} = ref} = Backend.open(hub_id, path: path)

      # Write directly into ETS, bypassing DETS. If reads went through
      # DETS, this row would be invisible.
      :ets.insert(ets_tid, {:ets_only, :ets_value})

      assert Backend.get(ref, :ets_only) === :ets_value
      assert Backend.exists?(ref, :ets_only) === true

      Backend.close(ref)
    end
  end

  describe "durability across reopen" do
    test "rows written via insert/3 survive close + reopen", %{hub_id: hub_id, path: path} do
      {:ok, ref} = Backend.open(hub_id, path: path)
      assert :ok = Backend.insert(ref, :persisted, :value)
      Backend.close(ref)

      {:ok, ref2} = Backend.open(hub_id, path: path)
      assert Backend.get(ref2, :persisted) === :value
      Backend.close(ref2)
    end

    test "removes also survive close + reopen", %{hub_id: hub_id, path: path} do
      {:ok, ref} = Backend.open(hub_id, path: path)
      assert :ok = Backend.insert(ref, :will_remove, :value)
      assert :ok = Backend.remove(ref, :will_remove)
      Backend.close(ref)

      {:ok, ref2} = Backend.open(hub_id, path: path)
      assert Backend.get(ref2, :will_remove) === nil
      Backend.close(ref2)
    end
  end

  describe "TTL" do
    test "expired entries return nil and are filtered from export_all", %{
      hub_id: hub_id,
      path: path
    } do
      {:ok, ref} = Backend.open(hub_id, path: path)

      # A live TTL is returned; an entry whose expiry is already in the past reads as expired.
      assert :ok = Backend.insert(ref, :live_key, :live_value, ttl: 60_000)
      assert Backend.get(ref, :live_key) === :live_value

      assert :ok = Backend.insert(ref, :ttl_key, :ttl_value, ttl: -1)

      assert Backend.get(ref, :ttl_key) === nil
      assert Backend.exists?(ref, :ttl_key) === false

      keys = Backend.export_all(ref) |> Enum.map(&elem(&1, 0))
      assert :live_key in keys
      refute :ttl_key in keys

      Backend.close(ref)
    end
  end

  describe "corruption rotation" do
    test "garbage file is rotated aside, logged, and ETS starts empty", %{
      hub_id: hub_id,
      path: path
    } do
      File.write!(path, "this is definitely not a valid dets file")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, {ets_tid, _} = ref} = Backend.open(hub_id, path: path)
          assert :ets.info(ets_tid, :size) === 0
          Backend.close(ref)
        end)

      assert log =~ "registry backend corrupt"
      assert length(Path.wildcard(path <> ".corrupt-*")) == 1
    end
  end

  describe "integration with the Initializer" do
    test "{:durable_ets, _} resolves and starts a hub", %{tmp_dir: tmp_dir} do
      hub_id = :"durable_ets_init_#{System.unique_integer([:positive])}"
      path = Path.join(tmp_dir, "init.dets")

      {:ok, pid} =
        ProcessHub.Initializer.start_link(%ProcessHub{
          hub_id: hub_id,
          registry_backend: {:durable_ets, path: path}
        })

      :erlang.unlink(pid)
      on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)

      assert ProcessHub.is_alive?(hub_id)
      assert File.exists?(path)
    end

    test "registry survives coordinator restart with :durable_ets", %{tmp_dir: tmp_dir} do
      hub_id = :"durable_ets_persist_#{System.unique_integer([:positive])}"
      path = Path.join(tmp_dir, "persist.dets")

      {:ok, pid1} =
        ProcessHub.Initializer.start_link(%ProcessHub{
          hub_id: hub_id,
          registry_backend: {:durable_ets, path: path}
        })

      :erlang.unlink(pid1)

      ProcessHub.Service.ProcessRegistry.bulk_insert(hub_id, %{
        :c1 => {%{id: :c1, start: {:m, :f, []}}, [{:n1, :p1}], %{}},
        :c2 => {%{id: :c2, start: {:m, :f, []}}, [{:n2, :p2}], %{}}
      })

      dump_before = ProcessHub.Service.ProcessRegistry.dump(hub_id)
      assert map_size(dump_before) === 2

      :ok = ProcessHub.Initializer.stop(hub_id)
      refute Process.whereis(hub_id)

      {:ok, pid2} =
        ProcessHub.Initializer.start_link(%ProcessHub{
          hub_id: hub_id,
          registry_backend: {:durable_ets, path: path}
        })

      :erlang.unlink(pid2)
      on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)

      dump_after = ProcessHub.Service.ProcessRegistry.dump(hub_id)
      assert dump_after === dump_before
    end
  end
end
