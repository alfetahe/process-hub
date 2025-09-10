defmodule ProcessHub.Strategy.Distribution.CentralizedScoreboard do
  @moduledoc """
  TODO:
  """

  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Hub
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
          sample_count: non_neg_integer(),
          last_updated: integer()
        }

  @type t() :: %__MODULE__{
          scoreboard: %{node() => node_score()},
          query_info_fn: (Hub.t() -> node_metrics()),
          calculate_score_fn: (Hub.t(), map(), node_metrics() -> node_score()),
          calculator_pid: pid() | nil,
          max_history_size: pos_integer(),
          weight_decay_factor: float()
        }
  defstruct scoreboard: %{},
            query_info_fn: &__MODULE__.default_query_info_fn/1,
            calculate_score_fn: &__MODULE__.default_calculate_score_fn/3,
            calculator_pid: nil,
            max_history_size: 20,
            weight_decay_factor: 0.9

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.CentralizedScoreboard do
    alias ProcessHub.Strategy.Distribution.CentralizedScoreboard

    @impl true
    def init(strategy, hub) do
      pid = CentralizedScoreboard.start_link({hub, strategy})

      Application.ensure_started(:elector)

      %CentralizedScoreboard{strategy | calculator_pid: pid}
    end

    @impl true
    def belongs_to(_strategy, _hub, child_ids, _replication_factor) do
      # TODO: Implement.
      Enum.map(child_ids, fn child_id ->
        {child_id, [node()]}
      end)
    end

    @impl true
    def children_init(_strategy, _hub, _child_specs, _opts), do: :ok
  end

  def start_link(args) do
    {:ok, pid} = GenServer.start_link(__MODULE__, args)
    pid
  end

  @impl true
  def init({hub, strategy}) do
    schedule_stats_push()

    {:ok, %{hub: hub, strategy: strategy}}
  end

  @impl true
  def handle_info(:schedule_stats_push, state) do
    local_stats = state.strategy.query_info_fn.(state.hub)

    case Elector.get_leader() do
      {:ok, leader_node} ->
        if leader_node === Node.self() do
          GenServer.cast(
            state.strategy.calculator_pid,
            {:calculate_score, Node.self(), local_stats}
          )
        else
          Node.spawn(leader_node, fn ->
            hub = ProcessHub.Coordinator.get_hub(state.hub.hub_id)

            GenServer.cast(
              hub.strategy.calculator_pid,
              {:calculate_score, Node.self(), local_stats}
            )
          end)
        end

      _ ->
        Logger.error("[ProcessHub][CentralizedScoreboard] Failed to get leader node.")
    end

    # Reschedule the next calculation.
    schedule_stats_push()

    {:noreply, state}
  end

  @impl true
  def handle_cast({:calculate_score, node, info}, state) do
    # Update the scoreboard with the new info from the node.
    node_score = state.strategy.calculate_score_fn.(state.hub, state.strategy.scoreboard, info)
    new_scoreboard = Map.put(state.strategy.scoreboard, node, node_score)
    updated_strategy = %{state.strategy | scoreboard: new_scoreboard}

    {:noreply, %{state | strategy: updated_strategy}}
  end

  @doc """
  Returns nodes sorted by their load score (lowest first).
  Nodes with lower scores are better candidates for new processes.
  """
  def get_sorted_nodes_by_load(strategy) do
    strategy.scoreboard
    |> Enum.sort_by(fn {_node, score} -> score.current_score end)
    |> Enum.map(fn {node, _score} -> node end)
  end

  @doc """
  Gets the scoreboard for debugging/monitoring purposes.
  """
  def get_scoreboard(strategy), do: strategy.scoreboard

  @doc """
  Collects BEAM VM metrics for load balancing decisions.
  Returns scheduler utilization, run queue lengths, process count, and memory usage.
  """
  def default_query_info_fn(_hub) do
    scheduler_usage = :scheduler.sample_all()
    scheduler_utilization = calculate_scheduler_utilization(scheduler_usage)

    run_queue_total =
      (:erlang.statistics(:run_queue) +
         :erlang.statistics(:run_queue_sizes_all))
      |> Enum.sum()

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

  @doc """
  Calculates a probabilistic load score for a node based on current and historical metrics.
  Lower scores indicate lower load (better for new process placement).
  Uses exponential moving average to give more weight to recent measurements.
  """
  def default_calculate_score_fn(hub, scoreboard, metrics) do
    strategy = hub.strategy
    current_node = Node.self()

    # Calculate current load score (normalized between 0 and 1)
    current_score = calculate_load_score(metrics)

    case Map.get(scoreboard, current_node) do
      nil ->
        # First measurement for this node
        %{
          current_score: current_score,
          historical_scores: [current_score],
          sample_count: 1,
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
          sample_count: existing_score.sample_count + 1,
          last_updated: metrics.timestamp
        }
    end
  end

  # Private helper functions for score calculations

  defp calculate_scheduler_utilization(scheduler_usage) do
    case scheduler_usage do
      :undefined ->
        0.0

      usage_data ->
        total_usage =
          Enum.reduce(usage_data, 0.0, fn {_id, active, total}, acc ->
            utilization = if total > 0, do: active / total, else: 0.0
            acc + utilization
          end)

        scheduler_count = length(usage_data)
        if scheduler_count > 0, do: total_usage / scheduler_count, else: 0.0
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

  defp schedule_stats_push() do
    # TODO: make the interval configurable.
    Process.send_after(self(), :schedule_stats_push, 5_000)
  end
end

# TODO: document that only one hub in the cluster should be able to use the centralized scoreboard strategy at the same time.
# TODO: handle node leave/join.
