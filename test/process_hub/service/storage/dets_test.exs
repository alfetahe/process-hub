defmodule Test.ProcessHub.Service.Storage.DetsTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Service.Storage.Dets, as: Backend

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "process_hub_dets_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    hub_id = :"dets_backend_test_#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "registry.dets")

    {:ok, %{hub_id: hub_id, path: path, tmp_dir: tmp_dir}}
  end

  test "open creates file at custom path", %{hub_id: hub_id, path: path} do
    {:ok, ref} = Backend.open(hub_id, path: path)
    assert ref === hub_id
    assert File.exists?(path)
    Backend.close(ref)
  end

  test "open uses default priv path when no :path option", %{hub_id: hub_id} do
    {:ok, ref} = Backend.open(hub_id, [])

    expected_dir =
      Path.join([
        File.cwd!(),
        "priv",
        "process_hub",
        Atom.to_string(hub_id)
      ])

    expected_path = Path.join(expected_dir, "registry.dets")

    on_exit(fn -> File.rm_rf!(expected_dir) end)

    assert File.exists?(expected_path)
    Backend.close(ref)
  end

  test "insert + get round-trip", %{hub_id: hub_id, path: path} do
    {:ok, ref} = Backend.open(hub_id, path: path)
    assert :ok = Backend.insert(ref, :k, :v)
    assert Backend.get(ref, :k) === :v
    assert Backend.get(ref, :missing) === nil
    Backend.close(ref)
  end

  test "values survive close + reopen (durability)", %{hub_id: hub_id, path: path} do
    {:ok, ref} = Backend.open(hub_id, path: path)
    Backend.insert(ref, :child1, {:cs1, [{:n1, :p1}], %{}})
    Backend.insert(ref, :child2, {:cs2, [{:n2, :p2}], %{}})
    :ok = Backend.close(ref)

    {:ok, ref2} = Backend.open(hub_id, path: path)
    assert Backend.get(ref2, :child1) === {:cs1, [{:n1, :p1}], %{}}
    assert Backend.get(ref2, :child2) === {:cs2, [{:n2, :p2}], %{}}
    Backend.close(ref2)
  end

  test "remove deletes a key durably", %{hub_id: hub_id, path: path} do
    {:ok, ref} = Backend.open(hub_id, path: path)
    Backend.insert(ref, :gone, :v)
    Backend.remove(ref, :gone)
    Backend.close(ref)

    {:ok, ref2} = Backend.open(hub_id, path: path)
    refute Backend.exists?(ref2, :gone)
    Backend.close(ref2)
  end

  test "clear_all empties the file", %{hub_id: hub_id, path: path} do
    {:ok, ref} = Backend.open(hub_id, path: path)
    Backend.insert(ref, :a, 1)
    Backend.insert(ref, :b, 2)
    assert :ok = Backend.clear_all(ref)
    assert Backend.export_all(ref) === []
    Backend.close(ref)
  end

  test "TTL emulation: get returns nil after expiry", %{hub_id: hub_id, path: path} do
    {:ok, ref} = Backend.open(hub_id, path: path)
    # A live TTL is returned; an entry whose expiry is already in the past reads as expired.
    Backend.insert(ref, :live_key, :live_value, ttl: 60_000)
    assert Backend.get(ref, :live_key) === :live_value
    Backend.insert(ref, :ttl_key, :ttl_value, ttl: -1)
    assert Backend.get(ref, :ttl_key) === nil
    refute Backend.exists?(ref, :ttl_key)
    Backend.close(ref)
  end

  test "export_all filters expired entries", %{hub_id: hub_id, path: path} do
    {:ok, ref} = Backend.open(hub_id, path: path)
    Backend.insert(ref, :alive, :v)
    Backend.insert(ref, :ttl_key, :v, ttl: -1)
    rows = Backend.export_all(ref)
    keys = Enum.map(rows, &elem(&1, 0))
    assert :alive in keys
    refute :ttl_key in keys
    Backend.close(ref)
  end

  test "match returns list of tuples", %{hub_id: hub_id, path: path} do
    {:ok, ref} = Backend.open(hub_id, path: path)
    Backend.insert(ref, :a, {:val_a, %{tag: "x"}})
    Backend.insert(ref, :b, {:val_b, %{tag: "x"}})
    Backend.insert(ref, :c, {:val_c, %{tag: "y"}})

    matches = Backend.match(ref, {:"$1", {:"$2", %{tag: "x"}}})
    assert length(matches) === 2
    assert Enum.all?(matches, &is_tuple/1)
    Backend.close(ref)
  end

  test "corrupt file is rotated aside, logged, and reopened empty", %{hub_id: hub_id, path: path} do
    File.write!(path, "this is not a valid dets file content garbage garbage garbage")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, ref} = Backend.open(hub_id, path: path)
        assert Backend.get(ref, :anything) == nil
        Backend.close(ref)
      end)

    assert log =~ "registry backend corrupt"
    assert length(Path.wildcard(path <> ".corrupt-*")) == 1
  end
end
