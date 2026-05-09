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
      assert cfg.recovery_window_ms == 10_000
      assert cfg.replay_timeout_ms == 60_000
    end

    test "true -> enabled with defaults" do
      assert {:ok, %{enabled?: true, recovery_window_ms: 10_000, replay_timeout_ms: 60_000}} =
               Recovery.parse_config(true)
    end

    test "valid keyword -> custom values" do
      assert {:ok, %{enabled?: true, recovery_window_ms: 30_000, replay_timeout_ms: 120_000}} =
               Recovery.parse_config(recovery_window_ms: 30_000, replay_timeout_ms: 120_000)
    end

    test "partial keyword fills in defaults" do
      assert {:ok, %{enabled?: true, recovery_window_ms: 5_000, replay_timeout_ms: 60_000}} =
               Recovery.parse_config(recovery_window_ms: 5_000)
    end

    test "out-of-range recovery_window_ms -> error" do
      assert {:error, {:invalid_auto_recovery, :recovery_window_ms_out_of_range}} =
               Recovery.parse_config(recovery_window_ms: 100)

      assert {:error, {:invalid_auto_recovery, :recovery_window_ms_out_of_range}} =
               Recovery.parse_config(recovery_window_ms: 10_000_000)
    end

    test "out-of-range replay_timeout_ms -> error" do
      assert {:error, {:invalid_auto_recovery, :replay_timeout_ms_out_of_range}} =
               Recovery.parse_config(replay_timeout_ms: 100)
    end

    test "unknown shape -> generic error" do
      assert {:error, :invalid_auto_recovery} = Recovery.parse_config(:bad)
      assert {:error, :invalid_auto_recovery} = Recovery.parse_config(%{enabled: true})
    end
  end

  describe "compute_transition/2" do
    test "recovery_pending + peer :normal triggers transition" do
      assert Recovery.compute_transition(:recovery_pending, :normal) ==
               {:transition, :normal, :peer_normal}
    end

    test "recovery_pending + peer :recovery_pending is no-op" do
      assert Recovery.compute_transition(:recovery_pending, :recovery_pending) == :no_change
    end

    test "recovery_pending + peer :recovering is no-op" do
      assert Recovery.compute_transition(:recovery_pending, :recovering) == :no_change
    end

    test "already :normal stays :normal" do
      assert Recovery.compute_transition(:normal, :normal) == :no_change
      assert Recovery.compute_transition(:normal, :recovery_pending) == :no_change
    end

    test "already :recovering stays :recovering" do
      assert Recovery.compute_transition(:recovering, :normal) == :no_change
    end
  end

  describe "any_peer_normal?/1" do
    test "empty map -> false" do
      assert Recovery.any_peer_normal?(%{}) == false
    end

    test "all peers pending -> false" do
      assert Recovery.any_peer_normal?(%{a: :recovery_pending, b: :recovering}) == false
    end

    test "at least one peer normal -> true" do
      assert Recovery.any_peer_normal?(%{a: :recovery_pending, b: :normal}) == true
    end
  end
end
