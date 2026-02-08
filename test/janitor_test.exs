defmodule Test.JanitorTest do
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Janitor

  use ExUnit.Case

  @hub_id :janitor_test

  setup_all do
    Test.Helper.SetupHelper.setup_base(%{}, @hub_id)
  end

  setup %{hub_id: hub_id} = context do
    on_exit(:clear_table, fn ->
      ProcessRegistry.clear_all(hub_id)
    end)

    context
  end

  describe "purge_pending_registry/1" do
    test "removes expired pending entries from registry", %{hub_id: hub_id} do
      # Insert a pending entry with an already-expired TTL
      child_spec = %{id: :pending_child_1, start: {TestModule, :start_link, []}}
      metadata = %{pending: true, forwarded_at: 1_234_567_890, target_nodes: [:node1]}

      # Insert via ProcessRegistry with a negative TTL to create an expired entry
      ProcessRegistry.insert(hub_id, child_spec, [], metadata: metadata, ttl: -1000)

      # Verify the entry exists
      assert :ets.lookup(hub_id, :pending_child_1) != []

      # Call purge directly
      Janitor.purge_pending_registry(hub_id)

      # Verify the entry was removed
      assert :ets.lookup(hub_id, :pending_child_1) == []
    end

    test "does not remove non-expired entries", %{hub_id: hub_id} do
      # Insert a pending entry with TTL in the future
      child_spec = %{id: :pending_child_2, start: {TestModule, :start_link, []}}
      metadata = %{pending: true, forwarded_at: 1_234_567_890, target_nodes: [:node2]}

      # Insert with future TTL (10 minutes from now)
      ProcessRegistry.insert(hub_id, child_spec, [], metadata: metadata, ttl: 600_000)

      # Call purge directly
      Janitor.purge_pending_registry(hub_id)

      # Verify the entry still exists
      assert :ets.lookup(hub_id, :pending_child_2) != []

      # Cleanup
      ProcessRegistry.delete(hub_id, :pending_child_2)
    end

    test "does not affect regular entries without TTL", %{hub_id: hub_id} do
      # Insert a regular entry (no TTL - 2-tuple format)
      child_spec = %{id: :regular_child, start: {TestModule, :start_link, []}}
      ProcessRegistry.insert(hub_id, child_spec, [{:node1, self()}], metadata: %{})

      # Call purge directly
      Janitor.purge_pending_registry(hub_id)

      # Verify the entry still exists
      assert ProcessRegistry.lookup(hub_id, :regular_child) != nil
    end

    test "handles multiple expired entries", %{hub_id: hub_id} do
      # Insert multiple expired pending entries
      Enum.each(1..5, fn i ->
        child_id = :"multi_pending_#{i}"
        child_spec = %{id: child_id, start: {TestModule, :start_link, []}}
        metadata = %{pending: true, forwarded_at: 1_234_567_890, target_nodes: [:node1]}
        ProcessRegistry.insert(hub_id, child_spec, [], metadata: metadata, ttl: -1000)
      end)

      # Verify entries exist
      Enum.each(1..5, fn i ->
        assert :ets.lookup(hub_id, :"multi_pending_#{i}") != []
      end)

      # Call purge directly
      Janitor.purge_pending_registry(hub_id)

      # Verify all entries were removed
      Enum.each(1..5, fn i ->
        assert :ets.lookup(hub_id, :"multi_pending_#{i}") == []
      end)
    end

    test "returns :ok", %{hub_id: hub_id} do
      assert Janitor.purge_pending_registry(hub_id) == :ok
    end
  end

  describe "dump/1 with TTL entries" do
    test "dump includes pending entries with TTL", %{hub_id: hub_id} do
      # Insert a pending entry with TTL
      child_spec = %{id: :dump_pending, start: {TestModule, :start_link, []}}
      metadata = %{pending: true, forwarded_at: 1_234_567_890, target_nodes: [:node1]}

      ProcessRegistry.insert(hub_id, child_spec, [], metadata: metadata, ttl: 600_000)

      # Verify dump returns the entry (without TTL in the result)
      dump = ProcessRegistry.dump(hub_id)
      assert Map.has_key?(dump, :dump_pending)
      assert dump[:dump_pending] == {child_spec, [], metadata}

      # Cleanup
      ProcessRegistry.delete(hub_id, :dump_pending)
    end
  end
end
