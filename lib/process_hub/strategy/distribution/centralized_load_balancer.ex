defmodule ProcessHub.Strategy.Distribution.CentralizedLoadBalancer do
  @moduledoc """
  Provides implementation for distribution behavior using centralized load balancing.

  This strategy implements a centralized approach to process distribution where a single
  leader node collects performance metrics from all nodes in the cluster and makes
  distribution decisions based on real-time load data.

  Unlike the `ProcessHub.Strategy.Distribution.ConsistentHashing` strategy that uses
  deterministic hash-based distribution, the centralized load balancer actively monitors
  cluster resources and dynamically assigns processes to the least loaded nodes.

  ## How It Works

  The centralized load balancer operates through a leader election mechanism:

  1. **Leader Election**: Uses the `:elector` library to elect a single leader node.
     The leader is determined by **highest uptime** - the node that has been running
     the longest becomes the leader. This selection criteria is currently not configurable.
  2. **Metrics Collection**: Each node periodically sends performance metrics to the leader
  3. **Load Scoring**: The leader calculates load scores based on multiple system metrics
  4. **Distribution**: New processes are assigned to nodes with the lowest load scores

  The load scoring algorithm considers the following BEAM VM metrics:
  - **Scheduler utilization** (40% weight) - CPU usage across schedulers
  - **Run queue length** (30% weight) - Number of processes waiting to run
  - **Process count** (20% weight) - Total number of processes on the node
  - **Memory usage** (10% weight) - Total memory consumption

  ## Key Characteristics

  ### No Process Replication
  > #### Important Limitation {: .warning}
  >
  > This strategy **does not support process replication**. Only a single instance
  > of each process can exist at any time across the cluster. This makes it unsuitable
  > for use cases requiring high availability through process redundancy.

  ### Experimental Status
  > #### Experimental Feature {: .warning}
  >
  > This distribution strategy is currently **experimental** and should not be used
  > in production environments without thorough testing. The implementation may
  > change in future versions.

  ### Single Hub Limitation
  > #### Configuration Constraint {: .warning}
  >
  > When ProcessHub is used with multiple different hubs and configurations,
  > **only one single hub** can be configured to use the centralized load balancer
  > strategy at any given time in the cluster.

  ### No Process Shuffling
  Unlike some distribution strategies, the centralized load balancer does **not**
  shuffle existing processes when new nodes join the cluster. New processes will
  be distributed to optimal nodes based on current load, but existing processes
  remain where they are. However, when a node leaves the cluster, its processes
  **will be redistributed** to other available nodes.

  ## Configuration Options

  The strategy can be configured using the following struct fields:

  - `:max_history_size` (default: `30`) - Maximum number of historical load scores
    to maintain for each node. Used for calculating weighted averages and trend analysis.

  - `:weight_decay_factor` (default: `0.9`) - Exponential decay factor applied to
    historical scores. Values closer to 1.0 give more weight to historical data,
    while values closer to 0.0 prioritize recent measurements.

  - `:push_interval` (default: `10_000`) - Interval in milliseconds between
    metric collection and transmission from each node to the leader.

  ## Usage Example

      iex> distribution_strategy = %ProcessHub.Strategy.Distribution.CentralizedLoadBalancer{
      iex>   max_history_size: 50,
      iex>   weight_decay_factor: 0.8,
      iex>   push_interval: 5_000
      iex> }
      iex>
      iex> hub_config = %ProcessHub{
      iex>   hub_id: :my_hub,
      iex>   distribution_strategy: distribution_strategy
      iex> }

  ## Comparison with ConsistentHashing

  | Feature | CentralizedLoadBalancer | ConsistentHashing |
  |---------|------------------------|-------------------|
  | **Distribution Basis** | Real-time load metrics | Deterministic hashing |
  | **Process Shuffling** | No (on node join) | Yes (minimal) |
  | **Replication Support** | No | Yes |
  | **Leader Dependency** | Yes | No |
  | **Production Ready** | No (experimental) | Yes |
  | **Multiple Hubs** | No (single hub only) | Yes |
  """

  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.StorageKey
  alias :elector, as: Elector

  use GenServer
  require Logger

  @type node_metrics() :: %{
          scheduler_utilization: float(),
          run_queue_total: non_neg_integer(),
          process_count: non_neg_integer(),
          memory_usage: non_neg_integer(),
          timestamp: integer()
        }

  @type node_score() :: %{
          current_score: float(),
          historical_scores: [float()],
          last_updated: integer()
        }

  @type t() :: %__MODULE__{
          scoreboard: %{node() => node_score()},
          calculator_pid: pid() | nil,
          max_history_size: pos_integer(),
          weight_decay_factor: float(),
          push_interval: pos_integer(),
          # Do not change.
          nodeup_redistribution: boolean()
        }
  defstruct scoreboard: %{},
            calculator_pid: nil,
            max_history_size: 30,
            weight_decay_factor: 0.9,
            push_interval: 10_000,
            nodeup_redistribution: false

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.CentralizedLoadBalancer do
    alias ProcessHub.Strategy.Distribution.CentralizedLoadBalancer

    @impl true
    def init(strategy, hub) do
      pid = CentralizedLoadBalancer.start_link({hub, strategy})

      Application.ensure_started(:elector)
      Application.put_env(:elector, :strategy_module, :elector_ut_high_strategy)
      Elector.elect()

      %CentralizedLoadBalancer{strategy | calculator_pid: pid}
    end

    @impl true
    def belongs_to(strategy, hub, child_ids, _replication_factor) do
      {:ok, leader_node} = Elector.get_leader()

      case leader_node === Node.self() do
        true ->
          local_belongs_to(strategy, child_ids)

        false ->
          node_list = Node.list(:this)

          case Enum.member?(node_list, leader_node) do
            false ->
              # Start new election if leader is unreachable.
              new_leader =
                case Elector.elect_sync() do
                  {:ok, leader_node} -> leader_node
                  {:error, _} -> Node.self()
                end

              case new_leader === Node.self() do
                true ->
                  local_belongs_to(strategy, child_ids)

                false ->
                  remote_belongs_to(hub.hub_id, new_leader, child_ids)
              end

            true ->
              remote_belongs_to(hub.hub_id, leader_node, child_ids)
          end
      end
    end

    @impl true
    def children_init(_strategy, _hub, _child_specs, _opts), do: :ok

    defp local_belongs_to(strategy, child_ids) do
      case strategy.scoreboard do
        scoreboard when map_size(scoreboard) == 0 ->
          # Fallback to current node selection if no scoreboard data
          Enum.map(child_ids, fn child_id ->
            {child_id, [node()]}
          end)

        scoreboard ->
          distribute_children_by_capacity(child_ids, scoreboard)
      end
    end

    defp remote_belongs_to(hub_id, leader_node, child_ids) do
      self = self()

      Node.spawn(leader_node, fn ->
        nhub = ProcessHub.Coordinator.get_hub(hub_id)

        dist_strat =
          Storage.get(
            nhub.storage.misc,
            StorageKey.strdist()
          )

        assignments =
          DistributionStrategy.belongs_to(dist_strat, nhub, child_ids, 1)

        send(self, {:child_assignments, assignments})
      end)

      receive do
        {:child_assignments, assignments} -> assignments
      after
        10_000 ->
          Logger.error(
            "[ProcessHub][CentralizedLoadBalancer] Timeout waiting for leader node response."
          )

          []
      end
    end

    defp distribute_children_by_capacity(child_ids, scoreboard) do
      # Calculate capacity for each node (higher capacity = lower load score)
      node_capacities =
        Enum.map(scoreboard, fn {node, score} ->
          # Invert score and ensure minimum 10% capacity
          capacity = max(0.1, 1.0 - score.current_score)
          {node, capacity}
        end)

      total_capacity =
        Enum.reduce(node_capacities, 0.0, fn {_node, capacity}, acc ->
          acc + capacity
        end)

      child_count = length(child_ids)

      # Calculate how many children each node should get
      node_allocations =
        Enum.map(node_capacities, fn {node, capacity} ->
          allocation = round(capacity / total_capacity * child_count)
          {node, allocation}
        end)

      # Distribute children using the calculated allocations
      distribute_with_allocations(child_ids, node_allocations)
    end

    defp distribute_with_allocations(child_ids, node_allocations) do
      # Create a list of nodes repeated by their allocation count
      node_list =
        Enum.flat_map(node_allocations, fn {node, allocation} ->
          List.duplicate(node, allocation)
        end)

      # Handle case where allocations don't sum to child count due to rounding
      final_node_list =
        case length(node_list) do
          node_count when node_count < length(child_ids) ->
            # Add extra nodes from highest capacity nodes
            extra_needed = length(child_ids) - node_count

            sorted_nodes =
              Enum.sort_by(node_allocations, fn {_node, allocation} ->
                -allocation
              end)

            extra_nodes =
              sorted_nodes
              |> Enum.take(extra_needed)
              |> Enum.map(fn {node, _} -> node end)

            node_list ++ extra_nodes

          node_count when node_count > length(child_ids) ->
            # Remove excess nodes
            Enum.take(node_list, length(child_ids))

          _ ->
            node_list
        end

      # Zip children with assigned nodes
      child_ids
      |> Enum.zip(final_node_list)
      |> Enum.map(fn {child_id, node} -> {child_id, [node]} end)
    end
  end

  def start_link(args) do
    {:ok, pid} = GenServer.start_link(__MODULE__, args)
    pid
  end

  @impl true
  def init({hub, strategy}) do
    :net_kernel.monitor_nodes(true)

    schedule_stats_push(strategy)

    {:ok, %{hub: hub}}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    # Remove node from scoreboard.
    strategy = Storage.get(state.hub.storage.misc, StorageKey.strdist())
    new_scoreboard = Map.delete(strategy.scoreboard, node)
    updated_strategy = %{strategy | scoreboard: new_scoreboard}
    Storage.insert(state.hub.storage.misc, StorageKey.strdist(), updated_strategy)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, _node}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:schedule_stats_push, strategy}, state) do
    local_stats = query_stats(state.hub)
    node = Node.self()

    case Elector.get_leader() do
      {:ok, leader_node} ->
        if leader_node === Node.self() do
          GenServer.cast(
            self(),
            {:calculate_score, node, local_stats}
          )
        else
          Node.spawn(leader_node, fn ->
            hub = ProcessHub.Coordinator.get_hub(state.hub.hub_id)

            dist_strat =
              Storage.get(
                hub.storage.misc,
                StorageKey.strdist()
              )

            GenServer.cast(
              dist_strat.calculator_pid,
              {:calculate_score, node, local_stats}
            )
          end)
        end

      _ ->
        Logger.error("[ProcessHub][CentralizedLoadBalancer] Failed to get leader node.")
    end

    # Reschedule the next calculation.
    schedule_stats_push(strategy)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:calculate_score, node, stats}, state) do
    strategy = Storage.get(state.hub.storage.misc, StorageKey.strdist())

    # Make sure the strategy exists in the cache.
    # It may not exist if the coordinator has not yet stored
    # it before the first stats push.
    case strategy do
      nil ->
        {:noreply, state}

      _ ->
        # Update the scoreboard with the new info from the node.
        node_score = calculate_score(state.hub, strategy, stats)
        new_scoreboard = Map.put(strategy.scoreboard, node, node_score)
        updated_strategy = %{strategy | scoreboard: new_scoreboard}

        # Dispatch hook event.
        HookManager.dispatch_hook(
          state.hub.storage.hook,
          :scoreboard_updated,
          {strategy.scoreboard, node}
        )

        # Persist updated strategy.
        Storage.insert(state.hub.storage.misc, StorageKey.strdist(), updated_strategy)
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_scoreboard, _from, state) do
    strategy = Storage.get(state.hub.storage.misc, StorageKey.strdist())

    {:reply, strategy.scoreboard, state}
  end

  @impl true
  def handle_call({:set_scoreboard, new_scoreboard}, _from, state) do
    strategy = Storage.get(state.hub.storage.misc, StorageKey.strdist())

    updated_strategy = %{strategy | scoreboard: new_scoreboard}
    Storage.insert(state.hub.storage.misc, StorageKey.strdist(), updated_strategy)

    {:reply, :ok, state}
  end

  @doc """
  Gets the scoreboard for debugging/monitoring purposes.
  """
  def get_scoreboard(strategy), do: strategy.scoreboard

  # Private helper functions for score calculations

  # Collects BEAM VM metrics for load balancing decisions.
  # Returns scheduler utilization, run queue lengths, process count, and memory usage.
  defp query_stats(_hub) do
    scheduler_usage = :scheduler.sample_all()
    scheduler_utilization = calculate_scheduler_utilization(scheduler_usage)

    run_queue_total = :erlang.statistics(:run_queue)

    process_count = :erlang.system_info(:process_count)
    memory_usage = :erlang.memory(:total)

    %{
      scheduler_utilization: scheduler_utilization,
      run_queue_total: run_queue_total,
      process_count: process_count,
      memory_usage: memory_usage,
      timestamp: System.system_time(:millisecond)
    }
  end

  # Calculates a probabilistic load score for a node based on current and historical metrics.
  # Lower scores indicate lower load (better for new process placement).
  # Uses exponential moving average to give more weight to recent measurements.
  defp calculate_score(_hub, strategy, metrics) do
    scoreboard = strategy.scoreboard
    current_node = Node.self()

    # Calculate current load score (normalized between 0 and 1)
    current_score = calculate_load_score(metrics)

    case Map.get(scoreboard, current_node) do
      nil ->
        # First measurement for this node
        %{
          current_score: current_score,
          historical_scores: [current_score],
          last_updated: metrics.timestamp
        }

      existing_score ->
        # Update existing score with exponential moving average
        updated_historical =
          update_historical_scores(
            existing_score.historical_scores,
            current_score,
            strategy.max_history_size
          )

        # Calculate weighted average with decay factor
        weighted_score =
          calculate_weighted_average(
            updated_historical,
            strategy.weight_decay_factor
          )

        %{
          current_score: weighted_score,
          historical_scores: updated_historical,
          last_updated: metrics.timestamp
        }
    end
  end

  defp calculate_scheduler_utilization(scheduler_usage) do
    case scheduler_usage do
      :undefined ->
        0.0

      {:scheduler_wall_time_all, usage_data} ->
        total_usage =
          Enum.reduce(usage_data, 0.0, fn
            {_type, _id, active, total}, acc ->
              utilization = if total > 0, do: active / total, else: 0.0
              acc + utilization

            {_id, active, total}, acc ->
              utilization = if total > 0, do: active / total, else: 0.0
              acc + utilization
          end)

        scheduler_count = length(usage_data)
        if scheduler_count > 0, do: total_usage / scheduler_count, else: 0.0

      usage_data when is_list(usage_data) ->
        total_usage =
          Enum.reduce(usage_data, 0.0, fn
            {_type, _id, active, total}, acc ->
              utilization = if total > 0, do: active / total, else: 0.0
              acc + utilization

            {_id, active, total}, acc ->
              utilization = if total > 0, do: active / total, else: 0.0
              acc + utilization
          end)

        scheduler_count = length(usage_data)
        if scheduler_count > 0, do: total_usage / scheduler_count, else: 0.0

      _ ->
        0.0
    end
  end

  defp calculate_load_score(metrics) do
    # Normalize metrics to 0-1 scale and combine with weights
    scheduler_score = min(metrics.scheduler_utilization, 1.0)

    # Normalize run queue (assuming typical values 0-100)
    run_queue_score = min(metrics.run_queue_total / 100.0, 1.0)

    # Normalize process count (assuming typical values 0-10000)
    process_score = min(metrics.process_count / 10_000.0, 1.0)

    # Normalize memory usage (assuming typical values 0-1GB)
    memory_score = min(metrics.memory_usage / (1024 * 1024 * 1024), 1.0)

    # Weighted combination of metrics
    scheduler_score * 0.4 + run_queue_score * 0.3 + process_score * 0.2 + memory_score * 0.1
  end

  defp update_historical_scores(historical_scores, new_score, max_size) do
    updated_scores = [new_score | historical_scores]

    if length(updated_scores) > max_size do
      Enum.take(updated_scores, max_size)
    else
      updated_scores
    end
  end

  defp calculate_weighted_average(scores, decay_factor) do
    {weighted_sum, weight_sum} =
      scores
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0}, fn {score, index}, {sum, weights} ->
        weight = :math.pow(decay_factor, index)
        {sum + score * weight, weights + weight}
      end)

    if weight_sum > 0, do: weighted_sum / weight_sum, else: 0.0
  end

  defp schedule_stats_push(strategy) do
    Process.send_after(self(), {:schedule_stats_push, strategy}, strategy.push_interval)
  end
end
