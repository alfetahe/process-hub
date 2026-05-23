defmodule Test.ProcessHubOracleTest do
  @moduledoc """
  Increment 3 — single-node oracle behaviour: lifecycle on the leader, hub
  directory, cluster info/stats, and the single-serializer `coordinate/2`.
  """
  use ExUnit.Case

  alias ProcessHub.Service.Leadership
  alias ProcessHub.Service.Oracle
  alias Test.Helper.Common

  setup do
    # Force-stop elector even if another test left it running, for a clean slate.
    Leadership.stop()
    Application.stop(:elector)
    on_exit(fn -> Leadership.stop() end)
    :ok
  end

  defp wait_for_oracle(), do: Common.eventually(fn -> Oracle.whereis() != :undefined end)

  test "client API returns {:error, :no_oracle} when leadership is not started" do
    refute ProcessHub.is_leader?()
    assert Oracle.list_hubs() == {:error, :no_oracle}
    assert Oracle.info() == {:error, :no_oracle}
  end

  test "the oracle starts as a single instance on the leader node" do
    assert ProcessHub.start_leadership() == :ok
    assert wait_for_oracle()

    pid = Oracle.whereis()
    assert is_pid(pid)
    assert node(pid) == node()
  end

  test "hub directory: announce, list, withdraw, and opt-in isolation" do
    assert ProcessHub.start_leadership() == :ok
    assert wait_for_oracle()

    assert Oracle.Manager.announce(:hub_a, %{role: :primary}) == :ok

    hubs = Oracle.list_hubs()
    assert Enum.any?(hubs, &(&1.hub_id == :hub_a and &1.node == node() and &1.metadata == %{role: :primary}))

    # A hub that never announced does not appear (opt-in participation).
    refute Enum.any?(hubs, &(&1.hub_id == :not_announced))

    assert Oracle.Manager.withdraw(:hub_a) == :ok
    refute Enum.any?(Oracle.list_hubs(), &(&1.hub_id == :hub_a))
  end

  test "info returns the leader, known hubs, and basic stats" do
    assert ProcessHub.start_leadership() == :ok
    assert wait_for_oracle()
    assert Oracle.Manager.announce(:hub_info, %{}) == :ok

    info = Oracle.info()
    assert info.leader == node()
    assert Enum.any?(info.hubs, &(&1.hub_id == :hub_info))
    assert info.stats.hub_count >= 1
    assert info.stats.node_count >= 1
  end

  test "coordinate/2 admits work once per key and de-duplicates" do
    assert ProcessHub.start_leadership() == :ok
    assert wait_for_oracle()
    parent = self()

    assert {:ok, :ran} = Oracle.coordinate(:k1, fn -> send(parent, :work_ran) && :ran end)

    assert {:already_done, :ran} =
             Oracle.coordinate(:k1, fn -> send(parent, :work_ran_again) && :ran end)

    assert_received :work_ran
    refute_received :work_ran_again
  end

  test "coordinate/2 isolates a failing work item and keeps the oracle alive" do
    assert ProcessHub.start_leadership() == :ok
    assert wait_for_oracle()
    pid = Oracle.whereis()

    assert {:error, {_kind, _reason}} = Oracle.coordinate(:boom, fn -> raise "boom" end)

    # The shared oracle did not crash, and failures are not cached (retryable).
    assert Oracle.whereis() == pid
    assert {:ok, :recovered} = Oracle.coordinate(:boom, fn -> :recovered end)
  end
end
