defmodule ProcessHub.Constant.StorageKey do
  @spec strred() :: :redundancy_strategy
  def strred, do: :redundancy_strategy
  @spec strsyn() :: :synchronization_strategy
  def strsyn, do: :synchronization_strategy
  @spec strmigr() :: :migration_strategy
  def strmigr, do: :migration_strategy
  @spec strdist() :: :distribution_strategy
  def strdist, do: :distribution_strategy
  @spec strpart() :: :partition_tolerance_strategy
  def strpart, do: :partition_tolerance_strategy
  @spec staticcs() :: :static_child_specs
  def staticcs, do: :static_child_specs

  @spec hdi() :: :hubs_discover_interval
  def hdi, do: :hubs_discover_interval
  @spec hn() :: :hub_nodes
  def hn, do: :hub_nodes
  @spec hr() :: :hash_ring
  def hr, do: :hash_ring
  @spec gdc() :: :guided_distribution_cache
  def gdc, do: :guided_distribution_cache
  def msk, do: :migration_hotswap_state
  @spec dqdn() :: :dynamic_quorum_down_nodes
  def dqdn, do: :dynamic_quorum_down_nodes
  def mqms, do: :majority_quorum_max_seen
  @spec gct() :: :gossip_node_timestamps
  def gct, do: :gossip_node_timestamps
  @spec dlrt() :: :deadlock_recovery_timeout
  def dlrt, do: :deadlock_recovery_timeout
  @spec hodw() :: :handover_data_wait
  def hodw, do: :handover_data_wait
  @spec mbt() :: :migration_base_timeout
  def mbt, do: :migration_base_timeout
  @spec ebd() :: :event_batch_delay
  def ebd, do: :event_batch_delay
end
