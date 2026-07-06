defmodule Test.ProcessHubPersistenceTest do
  @moduledoc """
  End-to-end tests for the opt-in persistent registry backend.

  Each test starts a real `ProcessHub` instance, exercises the registry,
  and asserts behaviour at the storage layer.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Service.ProcessRegistry

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "ph_persist_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, %{tmp_dir: tmp_dir}}
  end

  test "DETS backend: registry survives coordinator restart", %{tmp_dir: tmp_dir} do
    hub_id = :"persist_survive_#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "registry.dets")

    {:ok, pid} =
      ProcessHub.Initializer.start_link(%ProcessHub{
        hub_id: hub_id,
        registry_backend: {:dets, path: path}
      })

    :erlang.unlink(pid)

    children = [
      {:c1, {%{id: :c1, start: {:m, :f, []}}, [{:n1, :p1}], %{}}},
      {:c2, {%{id: :c2, start: {:m, :f, []}}, [{:n2, :p2}], %{tag: "x"}}},
      {:c3, {%{id: :c3, start: {:m, :f, []}}, [{:n3, :p3}], %{}}}
    ]

    ProcessRegistry.bulk_insert(hub_id, Map.new(children))

    dump_before = ProcessRegistry.dump(hub_id)
    assert map_size(dump_before) === 3

    :ok = ProcessHub.Initializer.stop(hub_id)
    refute Process.whereis(hub_id)

    {:ok, pid2} =
      ProcessHub.Initializer.start_link(%ProcessHub{
        hub_id: hub_id,
        registry_backend: {:dets, path: path}
      })

    :erlang.unlink(pid2)
    on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)

    dump_after = ProcessRegistry.dump(hub_id)

    assert dump_after === dump_before
    assert Map.has_key?(dump_after, :c1)
    assert Map.has_key?(dump_after, :c2)
    assert Map.has_key?(dump_after, :c3)
  end

  test "DETS backend: corrupt file is rotated on open", %{tmp_dir: tmp_dir} do
    hub_id = :"persist_corrupt_#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "registry.dets")

    File.write!(path, "this is definitely not a valid dets file")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, pid} =
          ProcessHub.Initializer.start_link(%ProcessHub{
            hub_id: hub_id,
            registry_backend: {:dets, path: path}
          })

        :erlang.unlink(pid)
        on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)
        assert ProcessRegistry.dump(hub_id) === %{}
      end)

    assert log =~ "registry backend corrupt"
    assert Path.wildcard(path <> ".corrupt-*") != []
  end

  test "default config (no :registry_backend) does NOT create a DETS file" do
    hub_id = :"persist_default_#{System.unique_integer([:positive])}"

    expected_dir =
      Path.join([File.cwd!(), "priv", "process_hub", Atom.to_string(hub_id)])

    refute File.exists?(expected_dir)

    {:ok, pid} = ProcessHub.Initializer.start_link(%ProcessHub{hub_id: hub_id})
    :erlang.unlink(pid)

    on_exit(fn ->
      ProcessHub.Initializer.stop(hub_id)
      File.rm_rf!(expected_dir)
    end)

    refute File.exists?(expected_dir)

    ProcessRegistry.insert(hub_id, %{id: :foo, start: {:m, :f, []}}, [{:n1, :p1}])
    assert ProcessRegistry.lookup(hub_id, :foo) !== nil

    refute File.exists?(expected_dir)
  end

  test "custom backend module is dispatched through" do
    hub_id = :"persist_mock_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      ProcessHub.Initializer.start_link(%ProcessHub{
        hub_id: hub_id,
        registry_backend: {Test.Support.MockStorage, [tag: hub_id]}
      })

    :erlang.unlink(pid)
    on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)

    assert Test.Support.MockStorage.opened?(hub_id)

    ProcessRegistry.insert(hub_id, %{id: :mock_child, start: {:m, :f, []}}, [{:n1, :p1}])

    assert Test.Support.MockStorage.last_op(hub_id) in [:insert, :get]
    assert ProcessRegistry.lookup(hub_id, :mock_child) !== nil
  end
end
