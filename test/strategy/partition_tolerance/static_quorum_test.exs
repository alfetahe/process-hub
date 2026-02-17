defmodule Test.Strategy.PartitionTolerance.StaticQuorumTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.PartitionTolerance.StaticQuorum
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey

  setup do
    hub_id = :"test_static_quorum_#{:erlang.unique_integer([:positive])}"
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

  describe "toggle_lock?/3" do
    test "returns true when nodes < quorum_size", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node()])
      strategy = %StaticQuorum{quorum_size: 3}

      assert PartitionToleranceStrategy.toggle_lock?(strategy, hub, :fake_node)
    end

    test "returns false when nodes >= quorum_size", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node(), :n2@host, :n3@host])
      strategy = %StaticQuorum{quorum_size: 3}

      refute PartitionToleranceStrategy.toggle_lock?(strategy, hub, :fake_node)
    end

    test "returns false when nodes exceed quorum_size", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node(), :n2@host, :n3@host, :n4@host])
      strategy = %StaticQuorum{quorum_size: 3}

      refute PartitionToleranceStrategy.toggle_lock?(strategy, hub, :fake_node)
    end
  end

  describe "toggle_unlock?/3" do
    test "returns true when nodes >= quorum_size", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node(), :n2@host, :n3@host])
      strategy = %StaticQuorum{quorum_size: 3}

      assert PartitionToleranceStrategy.toggle_unlock?(strategy, hub, :fake_node)
    end

    test "returns false when nodes < quorum_size", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node(), :n2@host])
      strategy = %StaticQuorum{quorum_size: 3}

      refute PartitionToleranceStrategy.toggle_unlock?(strategy, hub, :fake_node)
    end
  end

  describe "init/2 with startup_confirm: false" do
    test "returns strategy without side effects", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node()])
      strategy = %StaticQuorum{quorum_size: 5, startup_confirm: false}

      result = PartitionToleranceStrategy.init(strategy, hub)
      assert result == strategy
    end
  end

  describe "edge cases" do
    test "quorum_size=1 with single node has quorum", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node()])
      strategy = %StaticQuorum{quorum_size: 1}

      refute PartitionToleranceStrategy.toggle_lock?(strategy, hub, :fake)
      assert PartitionToleranceStrategy.toggle_unlock?(strategy, hub, :fake)
    end

    test "quorum_size equals cluster size", %{hub: hub} do
      nodes = [node(), :n2@host, :n3@host]
      Storage.insert(hub.storage.misc, StorageKey.hn(), nodes)
      strategy = %StaticQuorum{quorum_size: 3}

      # Exactly at quorum: has quorum
      refute PartitionToleranceStrategy.toggle_lock?(strategy, hub, :fake)
      assert PartitionToleranceStrategy.toggle_unlock?(strategy, hub, :fake)

      # Lose one node: below quorum
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node(), :n2@host])
      assert PartitionToleranceStrategy.toggle_lock?(strategy, hub, :n3@host)
      refute PartitionToleranceStrategy.toggle_unlock?(strategy, hub, :n3@host)
    end

    test "split-brain: 5-node cluster split 3-2 with quorum_size 3", %{hub: hub} do
      all_nodes = [node(), :n2@host, :n3@host, :n4@host, :n5@host]
      Storage.insert(hub.storage.misc, StorageKey.hn(), all_nodes)
      strategy = %StaticQuorum{quorum_size: 3}

      # Majority side (3 nodes): has quorum
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node(), :n2@host, :n3@host])
      refute PartitionToleranceStrategy.toggle_lock?(strategy, hub, :n4@host)

      # Minority side (2 nodes): no quorum
      Storage.insert(hub.storage.misc, StorageKey.hn(), [:n4@host, :n5@host])
      assert PartitionToleranceStrategy.toggle_lock?(strategy, hub, :n3@host)
    end
  end
end
