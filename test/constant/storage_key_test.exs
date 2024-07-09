defmodule Test.Constant.StorageKeyTest do
  use ExUnit.Case

  alias ProcessHub.Constant.StorageKey

  test "storage key redundancy strategy" do
    assert StorageKey.strred() === :redundancy_strategy
  end

  test "storage key synchronization strategy" do
    assert StorageKey.strsyn() === :synchronization_strategy
  end

  test "storage key migration strategy" do
    assert StorageKey.strmigr() === :migration_strategy
  end

  test "storage key distribution strategy" do
    assert StorageKey.strdist() === :distribution_strategy
  end

  test "storage key partition tolerance strategy" do
    assert StorageKey.strpart() === :partition_tolerance_strategy
  end

  test "storage key hubs discover interval" do
    assert StorageKey.hdi() === :hubs_discover_interval
  end

  test "storage key hub nodes" do
    assert StorageKey.hn() === :hub_nodes
  end

  test "storage key hash ring" do
    assert StorageKey.hr() === :hash_ring
  end

  test "storage key guided distribution cache" do
    assert StorageKey.gdc() === :guided_distribution_cache
  end

  test "storage key migration hotswap state" do
    assert StorageKey.msk() === :migration_hotswap_state
  end

  test "storage key dynamic quorum down nodes" do
    assert StorageKey.dqdn() === :dynamic_quorum_down_nodes
  end

  test "storage key gossip node timestamps" do
    assert StorageKey.gct() === :gossip_node_timestamps
  end

  test "storage key deadlock recovery timeout" do
    assert StorageKey.dlrt() === :deadlock_recovery_timeout
  end

  test "storage key handover data wait" do
    assert StorageKey.hodw() === :handover_data_wait
  end

  test "storage key static child specs" do
    assert StorageKey.staticcs() === :static_child_specs
  end
end
