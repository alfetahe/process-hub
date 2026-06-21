defmodule Test.Strategy.Synchronization.GossipTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Synchronization.Gossip
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey

  setup do
    hub_id = :"test_gossip_#{:erlang.unique_integer([:positive])}"
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

    %{hub: hub}
  end

  describe "init/2" do
    test "returns strategy unchanged", %{hub: hub} do
      strategy = %Gossip{sync_interval: 5000}
      result = SynchronizationStrategy.init(strategy, hub)
      assert result == strategy
    end
  end

  describe "recipients_select/2" do
    test "selects up to N recipients" do
      nodes = [:n1@host, :n2@host, :n3@host, :n4@host, :n5@host]
      strategy = %Gossip{recipients: 3}

      result = Gossip.recipients_select(nodes, strategy)
      assert length(result) == 3
      assert Enum.all?(result, &(&1 in nodes))
    end

    test "returns all if fewer than recipients" do
      nodes = [:n1@host]
      strategy = %Gossip{recipients: 3}

      result = Gossip.recipients_select(nodes, strategy)
      assert result == [:n1@host]
    end

    test "returns empty for empty nodes" do
      strategy = %Gossip{recipients: 3}
      assert Gossip.recipients_select([], strategy) == []
    end
  end

  describe "unacked_nodes/2" do
    test "returns nodes not in ack list", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node(), :n2@host, :n3@host])

      result = Gossip.unacked_nodes([node()], hub.storage.misc)
      assert :n2@host in result
      assert :n3@host in result
      refute node() in result
    end

    test "returns empty when all acked", %{hub: hub} do
      nodes = [node()]
      Storage.insert(hub.storage.misc, StorageKey.hn(), nodes)

      result = Gossip.unacked_nodes([node()], hub.storage.misc)
      assert result == []
    end
  end

  describe "invalidate_ref/3" do
    test "stores :invalidated for ref", %{hub: hub} do
      strategy = %Gossip{}
      ref = make_ref()

      Gossip.invalidate_ref(strategy, hub.storage.misc, ref)

      assert Storage.get(hub.storage.misc, ref) == :invalidated
    end
  end

  describe "handle_propagation/3" do
    test "with invalidated ref returns :ok", %{hub: hub} do
      strategy = %Gossip{}
      ref = make_ref()
      Storage.insert(hub.storage.misc, ref, :invalidated)
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node()])

      result = Gossip.handle_propagation(strategy, hub, {ref, [], []})
      assert result == :ok
    end

    test "with fresh ref processes propagation", %{hub: hub} do
      strategy = %Gossip{}
      ref = make_ref()
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node()])

      # Register hub_id as process name so handle_request_propagation can send
      Process.register(self(), hub.hub_id)

      result = Gossip.handle_propagation(strategy, hub, {ref, [], []})
      assert result == :ok

      # Verify propagated message was sent to registered process
      assert_receive {_, []}
      # Gossip stores ack data for the ref in ETS
      ref_data = Storage.get(hub.storage.misc, ref)
      assert ref_data != nil

      Process.unregister(hub.hub_id)
    end
  end

  describe "handle_request_propagation/2" do
    test "sends event to hub_id process" do
      hub_id = :"gossip_hrp_#{:erlang.unique_integer([:positive])}"
      Process.register(self(), hub_id)

      Gossip.handle_request_propagation(hub_id, [:some_request])

      assert_receive {_, [:some_request]}

      Process.unregister(hub_id)
    end

    test "returns :ok when hub_id process doesn't exist" do
      # Should not crash, returns :ok via catch
      Gossip.handle_request_propagation(:nonexistent_hub_gossip, [:some_request])
    end
  end

  describe "propagate_data/4" do
    test "with empty nodes does nothing", %{hub: hub} do
      strategy = %Gossip{}
      result = Gossip.propagate_data([], hub, strategy, {make_ref(), [], []})
      assert result == :ok
    end
  end

  describe "struct defaults" do
    test "default values" do
      g = %Gossip{}
      assert g.sync_interval == 15000
      assert g.recipients == 3
      assert g.restricted_init == true
    end
  end
end

defmodule Test.Strategy.Synchronization.GossipIntegrationTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Synchronization.Gossip
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey

  setup_all do
    hub_id = :"gossip_int_test_#{:erlang.unique_integer([:positive])}"

    config = %ProcessHub{
      hub_id: hub_id,
      synchronization_strategy: %Gossip{sync_interval: 60_000, recipients: 3}
    }

    case ProcessHub.Initializer.start_link(config) do
      {:ok, pid} -> :erlang.unlink(pid)
      {:error, error} -> throw(error)
    end

    hub = ProcessHub.Coordinator.get_hub(hub_id)

    on_exit(:stop_hub, fn ->
      ProcessHub.Initializer.stop(hub_id)
    end)

    %{hub: hub, hub_id: hub_id}
  end

  describe "handle_synchronization/4 with Gossip hub" do
    test "fresh sync data", %{hub: hub} do
      strategy = %Gossip{}
      ref = make_ref()

      sync_data = %{
        ref: ref,
        nodes_data: %{node() => {[], System.system_time(:microsecond)}},
        sync_acks: []
      }

      result =
        SynchronizationStrategy.handle_synchronization(strategy, hub, sync_data, :remote@host)

      assert result == :ok

      # Gossip stores acks for the ref in ETS
      ref_data = Storage.get(hub.storage.misc, ref)
      assert ref_data != nil
    end
  end

  describe "merge stamping (empty-broadcast suppression)" do
    test "does not stamp this node's empty data when it has hosted nothing this boot",
         %{hub: hub} = _context do
      # Ensure this node is unpopulated (has hosted nothing since boot).
      Storage.remove(hub.storage.misc, StorageKey.rp())

      strategy = %Gossip{}
      ref = make_ref()
      ts = System.system_time(:microsecond)

      sync_data = %{
        ref: ref,
        nodes_data: %{:remote@host => {[{%{id: :rc}, self(), %{}}], ts}},
        sync_acks: []
      }

      SynchronizationStrategy.handle_synchronization(strategy, hub, sync_data, :remote@host)

      # This node stays in the payload for gossip convergence, but as the
      # non-authoritative :suppressed marker (never an empty list that peers
      # would apply via detach_data and delete our records).
      {merged, _acks} = Storage.get(hub.storage.misc, ref)
      assert {:suppressed, _ts} = Map.get(merged, node())
      assert Map.has_key?(merged, :remote@host)
    end
  end

  describe "handle_node_join_data/4 with Gossip hub" do
    test "fresh data processes node join", %{hub: hub} do
      strategy = %Gossip{}
      ref = make_ref()

      sync_data = %{
        ref: ref,
        nodes_data: %{:remote@host => {[], System.system_time(:microsecond)}},
        sync_acks: []
      }

      result =
        SynchronizationStrategy.handle_node_join_data(strategy, hub, sync_data, :remote@host)

      assert result == :ok

      # Gossip stores acks for the ref in ETS
      ref_data = Storage.get(hub.storage.misc, ref)
      assert ref_data != nil
    end
  end

  describe "broadcast_local_data/4 with Gossip hub" do
    test "broadcasts without crash", %{hub: hub} do
      strategy = %Gossip{}
      result = SynchronizationStrategy.broadcast_local_data(strategy, hub, [], [node()])
      assert result == :ok
    end
  end

  describe "init_sync/3 with Gossip hub" do
    test "with restricted_init true", %{hub: hub} do
      strategy = %Gossip{restricted_init: true}
      result = SynchronizationStrategy.init_sync(strategy, hub, [node()])
      assert result == :ok
    end

    test "with restricted_init false", %{hub: hub} do
      strategy = %Gossip{restricted_init: false}
      result = SynchronizationStrategy.init_sync(strategy, hub, [node()])
      assert result == :ok
    end
  end

  describe "propagate/3 via protocol with Gossip hub" do
    test "propagates requests without crash", %{hub: hub} do
      strategy = %Gossip{}
      result = SynchronizationStrategy.propagate(strategy, hub, [], [])
      assert result == :ok
    end
  end
end
