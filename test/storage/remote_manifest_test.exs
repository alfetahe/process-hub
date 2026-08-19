defmodule Test.Storage.RemoteManifestTest do
  @moduledoc """
  The remote-manifest behaviour: config validation, both built-in adapters
  against the shared contract suite, and the shipper's retry/coalesce loop.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Storage.RemoteManifest
  alias ProcessHub.Storage.RemoteManifest.LocalPath
  alias ProcessHub.Storage.RemoteManifest.S3
  alias ProcessHub.Storage.RemoteManifest.Shipper

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "ph_manifest_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "validate/1" do
    test "nil is valid, adapters validate their own opts" do
      assert RemoteManifest.validate(nil) == :ok
      assert RemoteManifest.validate({LocalPath, path: "/tmp/x"}) == :ok

      assert {:error, {:remote_manifest_module_missing, NoSuch.Adapter}} =
               RemoteManifest.validate({NoSuch.Adapter, []})

      assert {:error, {:remote_manifest_not_an_adapter, Enum}} =
               RemoteManifest.validate({Enum, []})

      assert {:error, {:local_path_requires_path, _}} = RemoteManifest.validate({LocalPath, []})
      assert {:error, :remote_manifest_invalid_shape} = RemoteManifest.validate(:bad)
    end

    test "the S3 adapter names its missing optional dependency" do
      # This repository does not depend on :ex_aws_s3, so the real check runs.
      assert {:error, {:missing_dependency, :ex_aws_s3}} =
               RemoteManifest.validate({S3, bucket: "b"})

      assert {:error, {:s3_requires_bucket, _}} = RemoteManifest.validate({S3, []})

      # An injected request_fun stands in for the dependency.
      assert RemoteManifest.validate({S3, bucket: "b", request_fun: fn _ -> :ok end}) == :ok
    end
  end

  describe "LocalPath specifics" do
    test "a corrupt manifest file is an error, not :not_found" do
      dir = tmp_dir!()
      File.write!(Path.join(dir, "corrupt_hub.manifest"), "not a term")

      assert {:error, :malformed_manifest_file} = LocalPath.fetch(:corrupt_hub, path: dir)
    end
  end
end

defmodule Test.Storage.RemoteManifestLocalPathContractTest do
  use ExUnit.Case, async: false
  use Test.Support.RemoteManifestContract, adapter: ProcessHub.Storage.RemoteManifest.LocalPath

  setup do
    dir = Path.join(System.tmp_dir!(), "ph_lp_contract_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, %{opts_fun: fn -> [path: dir] end}}
  end
end

defmodule Test.Storage.RemoteManifestS3ContractTest do
  use ExUnit.Case, async: false
  use Test.Support.RemoteManifestContract, adapter: ProcessHub.Storage.RemoteManifest.S3

  setup do
    # Linked to the test process, so it goes down with the test.
    {:ok, agent} = Test.Support.FakeS3.start_link()

    {:ok,
     %{opts_fun: fn -> [bucket: "b", request_fun: Test.Support.FakeS3.request_fun(agent)] end}}
  end
end

defmodule Test.Storage.RemoteManifestShipperTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Storage.RemoteManifest.Shipper
  alias ProcessHub.Utility.Bag

  # Test adapter: forwards each store attempt to the test process and obeys a
  # per-call verdict fetched from the controlling agent.
  defmodule Adapter do
    def store(hub_id, version, blob, opts) do
      send(Keyword.fetch!(opts, :notify), {:store_attempt, hub_id, version, blob})

      Agent.get_and_update(Keyword.fetch!(opts, :verdicts), fn
        [next | rest] -> {next, rest}
        [] -> {:ok, []}
      end)
    end

    def fetch(_hub_id, _opts), do: :not_found
    def info(_opts), do: %{adapter: :test}
  end

  defp manifest(version) do
    %{format: 1, version: version, mutated_by: node(), entries: %{}}
  end

  setup do
    {:ok, verdicts} = Agent.start_link(fn -> [] end)
    hook_storage = :ets.new(:shipper_hooks, [:set, :public])

    HookManager.register_handlers(hook_storage, Hook.manifest_ship_failed(), [
      Bag.recv_hook(:ship_failed, self())
    ])

    opts = [notify: self(), verdicts: verdicts]

    {:ok, pid} =
      Shipper.start_link(
        {:shipper_hub, :"shipper_#{System.unique_integer([:positive])}", {Adapter, opts},
         hook_storage}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, %{shipper: pid, verdicts: verdicts}}
  end

  test "ships the manifest once on success", %{shipper: shipper} do
    GenServer.cast(shipper, {:ship, manifest(3)})

    assert_receive {:store_attempt, :shipper_hub, 3, blob}, 2_000
    assert is_binary(blob)
    refute_receive {:store_attempt, _, _, _}, 300
    refute_receive {:ship_failed, _}, 100
  end

  test "retries with the failure hook and recovers", %{shipper: shipper, verdicts: verdicts} do
    Agent.update(verdicts, fn _ -> [{:error, :boom}] end)
    GenServer.cast(shipper, {:ship, manifest(4)})

    assert_receive {:store_attempt, :shipper_hub, 4, _blob}, 2_000
    assert_receive {:ship_failed, %{version: 4, error: :boom, attempt: 1}}, 2_000

    # The retry (backoff 1 s) succeeds against the now-empty verdict list.
    assert_receive {:store_attempt, :shipper_hub, 4, _blob}, 3_000
    refute_receive {:ship_failed, _}, 300
  end

  test "a newer version replaces the pending one", %{shipper: shipper, verdicts: verdicts} do
    Agent.update(verdicts, fn _ -> [{:error, :boom}, {:error, :boom}] end)
    GenServer.cast(shipper, {:ship, manifest(5)})
    assert_receive {:store_attempt, :shipper_hub, 5, _}, 2_000

    # While v5 waits out its backoff, v6 and then v7 arrive; each newer version
    # replaces the pending one, and once v7 lands nothing is retried again.
    GenServer.cast(shipper, {:ship, manifest(6)})
    assert_receive {:store_attempt, :shipper_hub, 6, _}, 2_000
    GenServer.cast(shipper, {:ship, manifest(7)})
    assert_receive {:store_attempt, :shipper_hub, 7, _}, 2_000

    # The stale backoff timers fire against an empty pending slot.
    refute_receive {:store_attempt, _, _, _}, 1_500
  end

  test "a superseded version is dropped without an attempt", %{shipper: shipper} do
    GenServer.cast(shipper, {:ship, manifest(9)})
    assert_receive {:store_attempt, :shipper_hub, 9, _}, 2_000

    GenServer.cast(shipper, {:ship, manifest(8)})
    refute_receive {:store_attempt, _, _, _}, 300
  end
end
