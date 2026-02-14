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

  test "storage key handover data wait" do
    assert StorageKey.hodw() === :handover_data_wait
  end

  test "storage key static child specs" do
    assert StorageKey.staticcs() === :static_child_specs
  end

  test "migration base timeout" do
    assert StorageKey.mbt() === :migration_base_timeout
  end

  test "request cleanup interval" do
    assert StorageKey.rci() === :req_cleanup_interval
  end

  test "storage key migration coldswap state" do
    assert StorageKey.mcsk() === :migration_coldswap_state
  end

  test "storage key majority quorum max seen" do
    assert StorageKey.mqms() === :majority_quorum_max_seen
  end

  test "storage key cluster event debounce" do
    assert StorageKey.ced() === :cluster_event_debounce
  end

  test "storage key cross node request timeout" do
    assert StorageKey.cnrt() === :cross_node_request_timeout
  end
end
