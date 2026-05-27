defmodule Test.Service.RecoveryMarkerTest do
  @moduledoc """
  Unit tests for the marker-gated recovery primitives:

    * `Recovery.parse_config/1` for `:recovery_timeout_ms`
    * `Recovery.parse_marker_config/2` and `resolve_marker_path/2`
    * `Recovery.resolve_mode/3` env-var precedence
    * `Recovery.marker_exists?/1`, `write_marker/1`, `delete_marker/1`
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ProcessHub.Service.Recovery

  defp tmp_path(suffix \\ "") do
    Path.join(System.tmp_dir!(), "process_hub_marker_#{System.unique_integer([:positive])}#{suffix}")
  end

  describe "parse_config/1 — recovery_timeout_ms" do
    test "true returns the default recovery_timeout_ms" do
      assert {:ok, %{recovery_timeout_ms: 30_000}} = Recovery.parse_config(true)
    end

    test "keyword accepts a custom recovery_timeout_ms" do
      assert {:ok, %{recovery_timeout_ms: 45_000}} =
               Recovery.parse_config(recovery_timeout_ms: 45_000)
    end

    test "out-of-range values are rejected" do
      assert {:error, {:invalid_auto_recovery, :recovery_timeout_ms_out_of_range}} =
               Recovery.parse_config(recovery_timeout_ms: 100)

      assert {:error, {:invalid_auto_recovery, :recovery_timeout_ms_out_of_range}} =
               Recovery.parse_config(recovery_timeout_ms: 10_000_000)
    end
  end

  describe "parse_marker_config/2" do
    test "nil defaults track auto_recovery_enabled?" do
      assert %{enabled?: true, path: nil} = Recovery.parse_marker_config(nil, true)
      assert %{enabled?: false, path: nil} = Recovery.parse_marker_config(nil, false)
    end

    test "explicit map values override the defaults" do
      assert %{enabled?: false, path: "/tmp/x"} =
               Recovery.parse_marker_config(%{enabled?: false, path: "/tmp/x"}, true)
    end

    test "keyword list shape works" do
      assert %{enabled?: true, path: "/tmp/k"} =
               Recovery.parse_marker_config([enabled?: true, path: "/tmp/k"], false)
    end
  end

  describe "resolve_marker_path/2" do
    test "explicit path is returned as-is" do
      assert Recovery.resolve_marker_path(:hub, "/var/lib/x") == "/var/lib/x"
    end

    test "nil path resolves under :user_data + hub_id" do
      assert Recovery.resolve_marker_path(:my_hub, nil) =~ "/my_hub/cluster.healthy"
    end
  end

  describe "resolve_mode/3" do
    test "env=force always selects :recovery" do
      assert :recovery = Recovery.resolve_mode("force", true, true)
      assert :recovery = Recovery.resolve_mode("force", false, true)
    end

    test "env=skip always selects :normal" do
      assert :normal = Recovery.resolve_mode("skip", true, true)
      assert :normal = Recovery.resolve_mode("skip", false, true)
    end

    test "env nil + marker present → :normal" do
      assert :normal = Recovery.resolve_mode(nil, true, true)
    end

    test "env nil + marker absent → :recovery" do
      assert :recovery = Recovery.resolve_mode(nil, false, true)
    end

    test "marker_enabled? false → :normal" do
      assert :normal = Recovery.resolve_mode(nil, false, false)
      assert :normal = Recovery.resolve_mode(nil, true, false)
      # env=force still wins per spec precedence (env beats marker.enabled?).
      assert :recovery = Recovery.resolve_mode("force", false, false)
    end

    test "unknown env falls back to :auto with WARN log" do
      log =
        capture_log(fn ->
          assert :recovery = Recovery.resolve_mode("garbage", false, true)
        end)

      assert log =~ "PROCESS_HUB_RECOVERY_MODE"
      assert log =~ "garbage"
    end
  end

  describe "marker_exists?/1" do
    test "false for nil and missing paths" do
      refute Recovery.marker_exists?(nil)
      refute Recovery.marker_exists?(tmp_path())
    end

    test "true for an existing zero-byte file" do
      path = tmp_path()
      File.touch!(path)
      on_exit(fn -> File.rm(path) end)
      assert Recovery.marker_exists?(path)
    end
  end

  describe "write_marker/1" do
    test "creates the parent directory and a zero-byte file" do
      base = tmp_path("_dir")
      path = Path.join(base, "cluster.healthy")
      on_exit(fn -> File.rm_rf(base) end)

      assert :ok = Recovery.write_marker(path)
      assert File.exists?(path)
      assert File.stat!(path).size == 0
    end

    test "is idempotent" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)
      assert :ok = Recovery.write_marker(path)
      assert :ok = Recovery.write_marker(path)
      assert File.exists?(path)
    end

    test "nil is a no-op" do
      assert :ok = Recovery.write_marker(nil)
    end
  end

  describe "delete_marker/1" do
    test "removes an existing marker" do
      path = tmp_path()
      File.touch!(path)
      assert :ok = Recovery.delete_marker(path)
      refute File.exists?(path)
    end

    test "is a no-op when the marker is absent" do
      assert :ok = Recovery.delete_marker(tmp_path())
    end

    test "nil is a no-op" do
      assert :ok = Recovery.delete_marker(nil)
    end
  end
end
