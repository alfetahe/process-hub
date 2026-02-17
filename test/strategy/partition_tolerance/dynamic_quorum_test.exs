defmodule Test.Strategy.PartitionTolerance.DynamicQuorumTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.PartitionTolerance.DynamicQuorum
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey

  setup do
    hub_id = :"test_dynamic_quorum_#{:erlang.unique_integer([:positive])}"
    misc_storage = :ets.new(hub_id, [:set, :public, :named_table])

    hub = %{
      hub_id: hub_id,
      storage: %{misc: misc_storage}
    }

    on_exit(fn ->
      if :ets.whereis(hub_id) != :undefined do
        :ets.delete(hub_id)
      end
    end)

    %{hub: hub, misc_storage: misc_storage}
  end

  describe "init/2" do
    test "returns strategy unchanged" do
      strategy = %DynamicQuorum{quorum_size: 50}
      assert PartitionToleranceStrategy.init(strategy, %{}) == strategy
    end
  end

  describe "toggle_lock?/3" do
    test "returns false when no nodes are down", %{hub: hub} do
      # 3 connected nodes, 0 down nodes = 100% quorum
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node(), :n2@host, :n3@host])
      strategy = %DynamicQuorum{quorum_size: 50, threshold_time: 30}

      refute PartitionToleranceStrategy.toggle_lock?(strategy, hub, :fake@host)
    end

    test "returns true when many nodes are down recently", %{hub: hub} do
      # Only 1 connected node with 3 recently downed nodes
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node()])

      # Pre-seed down nodes log with recent entries
      now = DateTime.utc_now() |> DateTime.to_unix(:second)

      Storage.insert(hub.storage.misc, StorageKey.dqdn(), [
        {:n2@host, now},
        {:n3@host, now},
        {:n4@host, now}
      ])

      strategy = %DynamicQuorum{quorum_size: 50, threshold_time: 30}

      # 1 connected / (1 + 3) = 25% quorum < 50%
      assert PartitionToleranceStrategy.toggle_lock?(strategy, hub, :n5@host)
    end

    test "returns false when threshold removes old entries", %{hub: hub} do
      # 2 connected, old downed entries should be filtered out
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node(), :n2@host])

      # Set old entries (older than threshold)
      old_time = DateTime.utc_now() |> DateTime.to_unix(:second) |> Kernel.-(100)

      Storage.insert(hub.storage.misc, StorageKey.dqdn(), [
        {:n3@host, old_time},
        {:n4@host, old_time}
      ])

      strategy = %DynamicQuorum{quorum_size: 50, threshold_time: 30}

      # toggle_lock? will call node_log_func which filters old entries
      # Then quorum check: 2 connected / (2 + 0 remaining down) = 100% > 50%
      refute PartitionToleranceStrategy.toggle_lock?(strategy, hub, :n5@host)
    end
  end

  describe "sync_quorum_log/2" do
    test "overwrites local log when remote is longer", %{hub: hub} do
      now = DateTime.utc_now() |> DateTime.to_unix(:second)

      # Local has 1 entry
      Storage.insert(hub.storage.misc, StorageKey.dqdn(), [{:n1@host, now}])

      # Remote has 3 entries
      remote_log = [{:n1@host, now}, {:n2@host, now}, {:n3@host, now}]
      DynamicQuorum.sync_quorum_log(hub, remote_log)

      result = Storage.get(hub.storage.misc, StorageKey.dqdn())
      assert length(result) == 3
    end

    test "keeps local log when local is longer", %{hub: hub} do
      now = DateTime.utc_now() |> DateTime.to_unix(:second)

      # Local has 3 entries
      local_log = [{:n1@host, now}, {:n2@host, now}, {:n3@host, now}]
      Storage.insert(hub.storage.misc, StorageKey.dqdn(), local_log)

      # Remote has 1 entry
      remote_log = [{:n1@host, now}]
      DynamicQuorum.sync_quorum_log(hub, remote_log)

      result = Storage.get(hub.storage.misc, StorageKey.dqdn())
      assert length(result) == 3
    end

    test "handles nil local log", %{hub: hub} do
      now = DateTime.utc_now() |> DateTime.to_unix(:second)
      remote_log = [{:n1@host, now}]

      DynamicQuorum.sync_quorum_log(hub, remote_log)

      result = Storage.get(hub.storage.misc, StorageKey.dqdn())
      assert result == remote_log
    end

    test "does not overwrite when logs are equal length", %{hub: hub} do
      now = DateTime.utc_now() |> DateTime.to_unix(:second)

      local_log = [{:n1@host, now}]
      Storage.insert(hub.storage.misc, StorageKey.dqdn(), local_log)

      remote_log = [{:n2@host, now}]
      DynamicQuorum.sync_quorum_log(hub, remote_log)

      # Local should remain unchanged since remote is not longer
      result = Storage.get(hub.storage.misc, StorageKey.dqdn())
      assert result == local_log
    end
  end

  describe "struct defaults" do
    test "threshold_time defaults to 30" do
      strategy = %DynamicQuorum{quorum_size: 50}
      assert strategy.threshold_time == 30
    end
  end
end
