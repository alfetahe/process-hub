defmodule ProcessHub.Constant.StorageKey do
  def strred, do: :redundancy_strategy
  def strsyn, do: :synchronization_strategy
  def strmigr, do: :migration_strategy
  def strdist, do: :distribution_strategy
  def strpart, do: :partition_tolerance_strategy

  def hdi, do: :hubs_discover_interval
  def hn, do: :hub_nodes
  def hr, do: :hash_ring
  def gdc, do: :guided_distribution_cache
  def msk, do: :migration_hotswap_state
  def dqdn, do: :dynamic_quorum_down_nodes
  def gct, do: :gossip_node_timestamps
  def dlrt, do: :deadlock_recovery_timeout
  def hodw, do: :handover_data_wait
end
