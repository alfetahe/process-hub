defmodule Test.ProcessHub.Service.Storage.DetsTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Service.Storage.Dets, as: Backend

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "process_hub_dets_test_#{System.unique_integer([:positive])}")
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
    Backend.insert(ref, :ttl_key, :ttl_value, ttl: 50)
    assert Backend.get(ref, :ttl_key) === :ttl_value
    Process.sleep(120)
    assert Backend.get(ref, :ttl_key) === nil
    refute Backend.exists?(ref, :ttl_key)
    Backend.close(ref)
  end

  test "export_all filters expired entries", %{hub_id: hub_id, path: path} do
    {:ok, ref} = Backend.open(hub_id, path: path)
    Backend.insert(ref, :alive, :v)
    Backend.insert(ref, :ttl_key, :v, ttl: 50)
    Process.sleep(120)
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

  test "telemetry: backend_opened fires on open", %{hub_id: hub_id, path: path} do
    handler_id = make_ref()
    parent = self()

    :telemetry.attach(
      handler_id,
      [:process_hub, :registry, :backend_opened],
      fn _event, measurements, metadata, _ ->
        send(parent, {:backend_opened, measurements, metadata})
      end,
      nil
    )

    {:ok, ref} = Backend.open(hub_id, path: path)
    assert_receive {:backend_opened, %{row_count: 0}, %{backend: ProcessHub.Service.Storage.Dets}},
                   500

    :telemetry.detach(handler_id)
    Backend.close(ref)
  end

  test "telemetry: backend_corrupt + rotation when file is unrepairable", %{
    hub_id: hub_id,
    path: path
  } do
    File.write!(path, "this is not a valid dets file content garbage garbage garbage")

    handler_id = make_ref()
    parent = self()

    :telemetry.attach(
      handler_id,
      [:process_hub, :registry, :backend_corrupt],
      fn _event, _measurements, metadata, _ ->
        send(parent, {:backend_corrupt, metadata})
      end,
      nil
    )

    {:ok, ref} = Backend.open(hub_id, path: path)
    assert_receive {:backend_corrupt, %{path: ^path, rotated_to: rotated}}, 1_000
    assert File.exists?(rotated)
    assert String.contains?(rotated, ".corrupt-")

    :telemetry.detach(handler_id)
    Backend.close(ref)
  end

  test "telemetry: insert and remove emit events", %{hub_id: hub_id, path: path} do
    {:ok, ref} = Backend.open(hub_id, path: path)
    parent = self()
    insert_handler = make_ref()
    remove_handler = make_ref()

    :telemetry.attach(
      insert_handler,
      [:process_hub, :registry, :insert],
      fn _e, m, md, _ -> send(parent, {:tel_insert, m, md}) end,
      nil
    )

    :telemetry.attach(
      remove_handler,
      [:process_hub, :registry, :remove],
      fn _e, m, md, _ -> send(parent, {:tel_remove, m, md}) end,
      nil
    )

    Backend.insert(ref, :ck, :cv)
    assert_receive {:tel_insert, %{count: 1}, %{child_id: :ck}}, 500

    Backend.remove(ref, :ck)
    assert_receive {:tel_remove, %{count: 1}, %{child_id: :ck}}, 500

    :telemetry.detach(insert_handler)
    :telemetry.detach(remove_handler)
    Backend.close(ref)
  end
end
