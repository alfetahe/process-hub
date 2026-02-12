defmodule Test.Strategy.Distribution.CentralizedLoadBalancerTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Distribution.CentralizedLoadBalancer
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey

  setup do
    hub_id = :"test_clb_#{:erlang.unique_integer([:positive])}"
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
    test "returns false" do
      refute DistributionStrategy.deterministic?(%CentralizedLoadBalancer{})
    end
  end

  describe "get_scoreboard/1" do
    test "returns scoreboard from struct" do
      scoreboard = %{node1: %{current_score: 0.5}}
      strategy = %CentralizedLoadBalancer{scoreboard: scoreboard}
      assert CentralizedLoadBalancer.get_scoreboard(strategy) == scoreboard
    end

    test "returns empty map for default struct" do
      assert CentralizedLoadBalancer.get_scoreboard(%CentralizedLoadBalancer{}) == %{}
    end
  end

  describe "distribution_signature/2" do
    test "returns consistent hash for same inputs", %{hub: hub} do
      nodes = [node(), :n2@host]
      Storage.insert(hub.storage.misc, StorageKey.hn(), nodes)

      strategy = %CentralizedLoadBalancer{
        scoreboard: %{
          node() => %{current_score: 0.3, historical_scores: [0.3], last_updated: 100}
        }
      }

      sig1 = DistributionStrategy.distribution_signature(strategy, hub)
      sig2 = DistributionStrategy.distribution_signature(strategy, hub)

      assert sig1 == sig2
    end

    test "returns different hash when scoreboard changes", %{hub: hub} do
      nodes = [node(), :n2@host]
      Storage.insert(hub.storage.misc, StorageKey.hn(), nodes)

      strategy1 = %CentralizedLoadBalancer{
        scoreboard: %{
          node() => %{current_score: 0.3, historical_scores: [0.3], last_updated: 100}
        }
      }

      strategy2 = %CentralizedLoadBalancer{
        scoreboard: %{
          node() => %{current_score: 0.8, historical_scores: [0.8], last_updated: 200}
        }
      }

      sig1 = DistributionStrategy.distribution_signature(strategy1, hub)
      sig2 = DistributionStrategy.distribution_signature(strategy2, hub)

      assert sig1 != sig2
    end
  end

  describe "struct defaults" do
    test "has expected default values" do
      clb = %CentralizedLoadBalancer{}
      assert clb.scoreboard == %{}
      assert clb.calculator_pid == nil
      assert clb.max_history_size == 30
      assert clb.weight_decay_factor == 0.9
      assert clb.push_interval == 10_000
      assert clb.nodeup_redistribution == false
    end
  end

  describe "GenServer handle_info nodedown" do
    test "removes node from scoreboard in ETS", %{hub: hub} do
      strategy = %CentralizedLoadBalancer{
        scoreboard: %{
          :leaving@host => %{current_score: 0.5, historical_scores: [0.5], last_updated: 100},
          :staying@host => %{current_score: 0.3, historical_scores: [0.3], last_updated: 100}
        }
      }

      Storage.insert(hub.storage.misc, StorageKey.strdist(), strategy)

      pid = CentralizedLoadBalancer.start_link({hub, strategy})

      send(pid, {:nodedown, :leaving@host})
      # Use :sys.get_state as synchronization barrier
      :sys.get_state(pid)

      updated = Storage.get(hub.storage.misc, StorageKey.strdist())
      refute Map.has_key?(updated.scoreboard, :leaving@host)
      assert Map.has_key?(updated.scoreboard, :staying@host)

      GenServer.stop(pid)
    end
  end

  describe "GenServer handle_info nodeup" do
    test "is a no-op", %{hub: hub} do
      strategy = %CentralizedLoadBalancer{scoreboard: %{}}
      Storage.insert(hub.storage.misc, StorageKey.strdist(), strategy)

      pid = CentralizedLoadBalancer.start_link({hub, strategy})
      send(pid, {:nodeup, :new@host})
      :sys.get_state(pid)

      updated = Storage.get(hub.storage.misc, StorageKey.strdist())
      assert updated.scoreboard == %{}

      GenServer.stop(pid)
    end
  end

  describe "GenServer handle_cast calculate_score" do
    test "nil strategy is a no-op", %{hub: hub} do
      strategy = %CentralizedLoadBalancer{}

      pid = CentralizedLoadBalancer.start_link({hub, strategy})

      GenServer.cast(
        pid,
        {:calculate_score, node(),
         %{
           scheduler_utilization: 0.5,
           run_queue_total: 10,
           process_count: 500,
           memory_usage: 100_000_000,
           timestamp: System.system_time(:millisecond)
         }}
      )

      :sys.get_state(pid)

      assert Storage.get(hub.storage.misc, StorageKey.strdist()) == nil

      GenServer.stop(pid)
    end

    test "valid strategy updates scoreboard", %{hub: hub} do
      strategy = %CentralizedLoadBalancer{scoreboard: %{}}
      Storage.insert(hub.storage.misc, StorageKey.strdist(), strategy)

      pid = CentralizedLoadBalancer.start_link({hub, strategy})

      GenServer.cast(
        pid,
        {:calculate_score, node(),
         %{
           scheduler_utilization: 0.5,
           run_queue_total: 10,
           process_count: 500,
           memory_usage: 100_000_000,
           timestamp: System.system_time(:millisecond)
         }}
      )

      :sys.get_state(pid)

      updated = Storage.get(hub.storage.misc, StorageKey.strdist())
      assert Map.has_key?(updated.scoreboard, node())
      assert updated.scoreboard[node()].current_score > 0

      GenServer.stop(pid)
    end
  end

  describe "GenServer handle_call get_scoreboard" do
    test "returns scoreboard from ETS", %{hub: hub} do
      scoreboard = %{
        node() => %{current_score: 0.42, historical_scores: [0.42], last_updated: 100}
      }

      strategy = %CentralizedLoadBalancer{scoreboard: scoreboard}
      Storage.insert(hub.storage.misc, StorageKey.strdist(), strategy)

      pid = CentralizedLoadBalancer.start_link({hub, strategy})

      result = GenServer.call(pid, :get_scoreboard)
      assert result == scoreboard

      GenServer.stop(pid)
    end
  end

  describe "GenServer handle_call set_scoreboard" do
    test "updates scoreboard in ETS", %{hub: hub} do
      strategy = %CentralizedLoadBalancer{scoreboard: %{}}
      Storage.insert(hub.storage.misc, StorageKey.strdist(), strategy)

      pid = CentralizedLoadBalancer.start_link({hub, strategy})

      new_scoreboard = %{
        :new_node@host => %{current_score: 0.7, historical_scores: [0.7], last_updated: 200}
      }

      result = GenServer.call(pid, {:set_scoreboard, new_scoreboard})
      assert result == :ok

      updated = Storage.get(hub.storage.misc, StorageKey.strdist())
      assert updated.scoreboard == new_scoreboard

      GenServer.stop(pid)
    end
  end

  describe "GenServer handle_cast calculate_score with historical data" do
    test "updates existing score with exponential moving average", %{hub: hub} do
      # Set up initial scoreboard with existing score for the node
      initial_scoreboard = %{
        node() => %{
          current_score: 0.3,
          historical_scores: [0.3],
          last_updated: System.system_time(:millisecond) - 1000
        }
      }

      strategy = %CentralizedLoadBalancer{scoreboard: initial_scoreboard}
      Storage.insert(hub.storage.misc, StorageKey.strdist(), strategy)

      pid = CentralizedLoadBalancer.start_link({hub, strategy})

      # Send a second score calculation
      GenServer.cast(
        pid,
        {:calculate_score, node(),
         %{
           scheduler_utilization: 0.8,
           run_queue_total: 50,
           process_count: 2000,
           memory_usage: 500_000_000,
           timestamp: System.system_time(:millisecond)
         }}
      )

      :sys.get_state(pid)

      updated = Storage.get(hub.storage.misc, StorageKey.strdist())
      score_data = updated.scoreboard[node()]

      # Should have 2 entries in historical_scores
      assert length(score_data.historical_scores) == 2
      # Score should be a weighted average, different from the raw current score
      assert is_float(score_data.current_score)

      GenServer.stop(pid)
    end
  end

  describe "children_init/4" do
    test "returns :ok" do
      strategy = %CentralizedLoadBalancer{}
      assert DistributionStrategy.children_init(strategy, %{}, [], []) == :ok
    end
  end
end
