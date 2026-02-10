defmodule Test.HubTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Hub

  describe "default_batch_state/0" do
    test "returns map with nodes and timer_ref" do
      result = Hub.default_batch_state()
      assert result == %{nodes: [], timer_ref: nil}
    end

    test "nodes defaults to empty list" do
      assert Hub.default_batch_state().nodes == []
    end

    test "timer_ref defaults to nil" do
      assert Hub.default_batch_state().timer_ref == nil
    end
  end

  describe "Hub struct defaults" do
    test "pending_operations defaults to empty map" do
      hub = %Hub{}
      assert hub.pending_operations == %{}
    end

    test "event_batches has nodedown and cluster_join keys" do
      hub = %Hub{}
      assert Map.has_key?(hub.event_batches, :nodedown)
      assert Map.has_key?(hub.event_batches, :cluster_join)
    end

    test "event_batches nodedown is default batch state" do
      hub = %Hub{}
      assert hub.event_batches.nodedown == %{nodes: [], timer_ref: nil}
    end

    test "event_batches cluster_join is default batch state" do
      hub = %Hub{}
      assert hub.event_batches.cluster_join == %{nodes: [], timer_ref: nil}
    end

    test "hub_id defaults to nil" do
      hub = %Hub{}
      assert hub.hub_id == nil
    end
  end
end
