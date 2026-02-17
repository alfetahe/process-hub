defmodule Test.HubTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Hub

  describe "default_batch_state/0" do
    test "returns map with empty nodes list and nil timer_ref" do
      result = Hub.default_batch_state()
      assert result == %{nodes: [], timer_ref: nil}
    end
  end

  describe "Hub struct defaults" do
    test "has expected default values" do
      hub = %Hub{}
      assert hub.hub_id == nil
      assert hub.pending_operations == %{}
      assert hub.event_batches.nodedown == %{nodes: [], timer_ref: nil}
      assert hub.event_batches.cluster_join == %{nodes: [], timer_ref: nil}
    end
  end
end
