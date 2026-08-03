defmodule Test.JanitorTest do
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Worker.Janitor

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

    test "delete_if_expired returns false for a re-populated entry", %{hub_id: hub_id} do
      child_spec = %{id: :repop_guard, start: {TestModule, :start_link, []}}
      ProcessRegistry.insert(hub_id, child_spec, [], metadata: %{}, ttl: -1000)
      # Re-registration clears the TTL, turning the row into a permanent 2-tuple.
      ProcessRegistry.insert(hub_id, child_spec, [{:node1, self()}], metadata: %{})

      refute ProcessRegistry.delete_if_expired(hub_id, :repop_guard)
      assert ProcessRegistry.lookup(hub_id, :repop_guard) != nil
    end

    test "handles malformed 3-tuple entries gracefully" do
      # Create a public ETS table with a malformed 3-tuple that matches {$1, $2, $3}
      # but does NOT match [child_id, {child_spec, _nodes, metadata}, ttl_expire]
      table = :ets.new(:test_malformed_purge, [:set, :public])
      :ets.insert(table, {:malformed_child, "not_a_tuple_value", 0})

      # Should not crash — hits the catch-all `_ -> nil` branch
      assert Janitor.purge_pending_registry(table) == :ok
    end
  end

  describe "purge_expired_cache/1" do
    test "removes expired TTL entries from storage" do
      table = :ets.new(:test_purge_cache, [:set, :public])

      # Insert expired entry (TTL in the past)
      ProcessHub.Service.Storage.insert(table, :expired1, "val1", ttl: -5000)
      ProcessHub.Service.Storage.insert(table, :expired2, "val2", ttl: -1000)

      # Insert valid entry (TTL in the future)
      ProcessHub.Service.Storage.insert(table, :valid1, "val3", ttl: 600_000)

      # Insert non-TTL entry (2-tuple, should be untouched)
      ProcessHub.Service.Storage.insert(table, :no_ttl, "val4")

      assert Janitor.purge_expired_cache(table) === :ok

      # Expired entries removed
      assert ProcessHub.Service.Storage.get(table, :expired1) === nil
      assert ProcessHub.Service.Storage.get(table, :expired2) === nil

      # Valid TTL entry kept
      assert ProcessHub.Service.Storage.get(table, :valid1) === "val3"

      # Non-TTL entry kept
      assert ProcessHub.Service.Storage.get(table, :no_ttl) === "val4"
    end

    test "handles empty table" do
      table = :ets.new(:test_purge_empty, [:set, :public])
      assert Janitor.purge_expired_cache(table) === :ok
    end

    test "preserves entries whose TTL has not yet expired" do
      table = :ets.new(:test_purge_future, [:set, :public])

      ProcessHub.Service.Storage.insert(table, :future1, "a", ttl: 300_000)
      ProcessHub.Service.Storage.insert(table, :future2, "b", ttl: 600_000)

      Janitor.purge_expired_cache(table)

      assert ProcessHub.Service.Storage.get(table, :future1) === "a"
      assert ProcessHub.Service.Storage.get(table, :future2) === "b"
    end
  end

  describe "handle_info :ttl_cleanup full cycle" do
    test "cleans both cache and registry in a single cycle", %{hub: hub} = _context do
      # Set up expired cache entry
      ProcessHub.Service.Storage.insert(hub.storage.misc, :cycle_expired, "gone", ttl: -1000)

      # Set up expired registry entry
      child_spec = %{id: :cycle_reg_expired, start: {TestModule, :start_link, []}}
      metadata = %{pending: true, forwarded_at: 0, target_nodes: [:node1]}
      ProcessRegistry.insert(hub.hub_id, child_spec, [], metadata: metadata, ttl: -1000)

      # Set up valid entries that should survive
      ProcessHub.Service.Storage.insert(hub.storage.misc, :cycle_valid, "stays", ttl: 600_000)
      valid_spec = %{id: :cycle_reg_valid, start: {TestModule, :start_link, []}}
      ProcessRegistry.insert(hub.hub_id, valid_spec, [{:node1, self()}], metadata: %{})

      # Trigger the full cleanup cycle via the janitor process
      janitor_pid = GenServer.whereis(hub.procs.janitor)
      ref = Process.monitor(janitor_pid)
      send(janitor_pid, :ttl_cleanup)

      # Wait for the janitor to finish processing (it won't crash, so monitor stays clean)
      refute_receive {:DOWN, ^ref, :process, ^janitor_pid, _}, 200

      # Expired cache entry purged
      assert ProcessHub.Service.Storage.get(hub.storage.misc, :cycle_expired) === nil

      # Valid cache entry kept
      assert ProcessHub.Service.Storage.get(hub.storage.misc, :cycle_valid) === "stays"

      # Expired registry entry purged
      assert :ets.lookup(hub.hub_id, :cycle_reg_expired) === []

      # Valid registry entry kept
      assert ProcessRegistry.lookup(hub.hub_id, :cycle_reg_valid) !== nil
    end
  end

  describe "dump_all/1 with TTL entries" do
    test "dump_all includes pending entries with TTL", %{hub_id: hub_id} do
      # Insert a pending entry with TTL
      child_spec = %{id: :dump_pending, start: {TestModule, :start_link, []}}
      metadata = %{pending: true, forwarded_at: 1_234_567_890, target_nodes: [:node1]}

      ProcessRegistry.insert(hub_id, child_spec, [], metadata: metadata, ttl: 600_000)

      # dump_all returns entries including those with empty nodes
      dump = ProcessRegistry.dump_all(hub_id)
      assert Map.has_key?(dump, :dump_pending)
      assert dump[:dump_pending] == {child_spec, [], metadata}

      # dump (filtered) excludes entries with empty nodes
      filtered_dump = ProcessRegistry.dump(hub_id)
      refute Map.has_key?(filtered_dump, :dump_pending)

      # Cleanup
      ProcessRegistry.delete(hub_id, :dump_pending)
    end
  end
end
