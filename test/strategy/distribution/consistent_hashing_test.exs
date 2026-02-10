defmodule Test.Strategy.Distribution.ConsistentHashingTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Distribution.ConsistentHashing
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.Ring
  alias ProcessHub.Constant.StorageKey

  setup do
    hub_id = :"test_ch_#{:erlang.unique_integer([:positive])}"
    misc_storage = :ets.new(hub_id, [:set, :public, :named_table])
    hook_storage = :ets.new(:"hook_#{hub_id}", [:set, :public])

    hub = %ProcessHub.Hub{
      hub_id: hub_id,
      storage: %{misc: misc_storage, hook: hook_storage}
    }

    on_exit(fn ->
      if :ets.whereis(hub_id) != :undefined, do: :ets.delete(hub_id)

      try do
        :ets.delete(hook_storage)
      rescue
        _ -> :ok
      end
    end)

    %{hub: hub, misc_storage: misc_storage}
  end

  describe "deterministic?/1" do
    test "returns true" do
      assert DistributionStrategy.deterministic?(%ConsistentHashing{})
    end
  end

  describe "distribution_signature/2" do
    test "returns consistent hash for same node sets", %{hub: hub} do
      nodes = [node(), :n2@host, :n3@host]
      Storage.insert(hub.storage.misc, StorageKey.hn(), nodes)

      sig1 = DistributionStrategy.distribution_signature(%ConsistentHashing{}, hub)
      sig2 = DistributionStrategy.distribution_signature(%ConsistentHashing{}, hub)

      assert sig1 == sig2
    end

    test "returns different hash for different node sets", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node(), :n2@host])
      sig1 = DistributionStrategy.distribution_signature(%ConsistentHashing{}, hub)

      Storage.insert(hub.storage.misc, StorageKey.hn(), [node(), :n2@host, :n3@host])
      sig2 = DistributionStrategy.distribution_signature(%ConsistentHashing{}, hub)

      assert sig1 != sig2
    end

    test "signature is order-independent", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hn(), [:a@host, :b@host, :c@host])
      sig1 = DistributionStrategy.distribution_signature(%ConsistentHashing{}, hub)

      Storage.insert(hub.storage.misc, StorageKey.hn(), [:c@host, :a@host, :b@host])
      sig2 = DistributionStrategy.distribution_signature(%ConsistentHashing{}, hub)

      assert sig1 == sig2
    end
  end

  describe "init/2" do
    test "creates hash ring in storage", %{hub: hub} do
      nodes = [node(), :n2@host]
      Storage.insert(hub.storage.misc, StorageKey.hn(), nodes)

      DistributionStrategy.init(%ConsistentHashing{}, hub)

      hash_ring = Storage.get(hub.storage.misc, StorageKey.hr())
      assert hash_ring != nil
    end
  end

  describe "belongs_to/4" do
    test "maps child_ids to nodes consistently", %{hub: hub} do
      nodes = [node(), :n2@host, :n3@host]
      Storage.insert(hub.storage.misc, StorageKey.hn(), nodes)

      hash_ring = Ring.create_ring(nodes)
      Storage.insert(hub.storage.misc, StorageKey.hr(), hash_ring)

      strategy = %ConsistentHashing{}
      result = DistributionStrategy.belongs_to(strategy, hub, [:child1, :child2], 1)

      assert is_map(result)
      assert Map.has_key?(result, :child1)
      assert Map.has_key?(result, :child2)

      # Each child gets exactly 1 node (replication_factor=1)
      assert length(result[:child1]) == 1
      assert length(result[:child2]) == 1

      # Nodes should be from our cluster
      assert hd(result[:child1]) in nodes
      assert hd(result[:child2]) in nodes
    end

    test "returns consistent results for same input", %{hub: hub} do
      nodes = [node(), :n2@host, :n3@host]
      hash_ring = Ring.create_ring(nodes)
      Storage.insert(hub.storage.misc, StorageKey.hr(), hash_ring)

      strategy = %ConsistentHashing{}
      result1 = DistributionStrategy.belongs_to(strategy, hub, [:child1], 1)
      result2 = DistributionStrategy.belongs_to(strategy, hub, [:child1], 1)

      assert result1 == result2
    end

    test "with replication_factor > 1 returns multiple nodes", %{hub: hub} do
      nodes = [node(), :n2@host, :n3@host]
      hash_ring = Ring.create_ring(nodes)
      Storage.insert(hub.storage.misc, StorageKey.hr(), hash_ring)

      strategy = %ConsistentHashing{}
      result = DistributionStrategy.belongs_to(strategy, hub, [:child1], 2)

      assert length(result[:child1]) == 2
    end
  end

  describe "handle_node_join/2" do
    test "adds node to ring", %{hub: hub} do
      nodes = [node()]
      hash_ring = Ring.create_ring(nodes)
      Storage.insert(hub.storage.misc, StorageKey.hr(), hash_ring)

      ConsistentHashing.handle_node_join(hub, :new_node@host)

      updated_ring = Storage.get(hub.storage.misc, StorageKey.hr())
      # Verify the new node is in the ring by checking it can be assigned
      result = Ring.key_to_nodes(updated_ring, :some_key, 2)
      assert :new_node@host in result
    end
  end

  describe "handle_node_leave/2" do
    test "removes node from ring", %{hub: hub} do
      nodes = [node(), :leaving@host, :staying@host]
      hash_ring = Ring.create_ring(nodes)
      Storage.insert(hub.storage.misc, StorageKey.hr(), hash_ring)

      ConsistentHashing.handle_node_leave(hub, :leaving@host)

      updated_ring = Storage.get(hub.storage.misc, StorageKey.hr())
      # Verify the node is no longer in the ring
      result = Ring.key_to_nodes(updated_ring, :some_key, 2)
      refute :leaving@host in result
    end
  end

  describe "handle_shutdown/1" do
    test "removes local node from ring", %{hub: hub} do
      nodes = [node(), :other@host]
      hash_ring = Ring.create_ring(nodes)
      Storage.insert(hub.storage.misc, StorageKey.hr(), hash_ring)

      ConsistentHashing.handle_shutdown(hub)

      updated_ring = Storage.get(hub.storage.misc, StorageKey.hr())
      result = Ring.key_to_nodes(updated_ring, :some_key, 1)
      refute node() in result
    end
  end
end
