defmodule Test.ProcessHub.Service.RecoveryTest do
  @moduledoc """
  Unit tests for the pure helpers in `ProcessHub.Service.Recovery`.

  Replay execution and the blocking-hook variant are covered by the
  integration tests in `test/integration_test.exs` and the public-API
  tests in `test/process_hub_recovery_test.exs`.
  """
  use ExUnit.Case, async: true

  alias ProcessHub.Service.Recovery

  describe "parse_config/1" do
    test "false -> disabled" do
      assert {:ok, %{enabled?: false} = cfg} = Recovery.parse_config(false)
      assert cfg.replay_timeout_ms == 60_000
      assert cfg.recovery_timeout_ms == 30_000
      assert cfg.marker_path == nil
    end

    test "true -> enabled with defaults" do
      assert {:ok, %{enabled?: true, replay_timeout_ms: 60_000, marker_path: nil}} =
               Recovery.parse_config(true)
    end

    test "valid keyword -> custom values" do
      assert {:ok,
              %{
                enabled?: true,
                replay_timeout_ms: 120_000,
                recovery_timeout_ms: 45_000,
                marker_path: "/var/lib/hub/cluster.healthy"
              }} =
               Recovery.parse_config(
                 replay_timeout_ms: 120_000,
                 recovery_timeout_ms: 45_000,
                 marker_path: "/var/lib/hub/cluster.healthy"
               )
    end

    test "partial keyword fills in defaults" do
      assert {:ok, %{enabled?: true, replay_timeout_ms: 30_000, recovery_timeout_ms: 30_000}} =
               Recovery.parse_config(replay_timeout_ms: 30_000)
    end

    test "out-of-range replay_timeout_ms -> error" do
      assert {:error, {:invalid_auto_recovery, :replay_timeout_ms_out_of_range}} =
               Recovery.parse_config(replay_timeout_ms: 100)
    end

    test "out-of-range recovery_timeout_ms -> error" do
      assert {:error, {:invalid_auto_recovery, :recovery_timeout_ms_out_of_range}} =
               Recovery.parse_config(recovery_timeout_ms: 10_000_000)
    end

    test "invalid marker_path -> error" do
      assert {:error, {:invalid_auto_recovery, :invalid_marker_path}} =
               Recovery.parse_config(marker_path: 123)
    end

    test "unknown shape -> generic error" do
      assert {:error, :invalid_auto_recovery} = Recovery.parse_config(:bad)
      assert {:error, :invalid_auto_recovery} = Recovery.parse_config(%{enabled: true})
    end
  end
end
