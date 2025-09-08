defmodule ProcessHub.Strategy.Distribution.CentralizedScoreboard do
  @moduledoc """
  TODO:
  """

  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Hub
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias :elector, as: Elector

  use GenServer

  @type t() :: %__MODULE__{
          scoreboard: %{node() => pos_integer()},
          query_info_fn: (Hub.t() -> any()),
          calculate_score_fn: (Hub.t(), map(), any() -> any()),
          calculator_pid: pid() | nil
        }
  defstruct scoreboard: %{},
            query_info_fn: &default_query_info_fn/1,
            calculate_score_fn: &default_calculate_score_fn/3,
            calculator_pid: nil

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.CentralizedScoreboard do
    alias ProcessHub.Strategy.Distribution.CentralizedScoreboard

    @impl true
    def init(strategy, hub) do
      pid = CentralizedScoreboard.start_link({hub, strategy})

      Application.ensure_started(:elector)

      %__MODULE__{strategy | calculator_pid: pid}
    end

    @impl true
    def belongs_to(_strategy, hub, child_id, replication_factor) do
      nodes = Cluster.get_nodes(hub.storage.misc, [:include_local])
      Cluster.key_to_node(nodes, child_id, replication_factor)
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
    schedule_scores_calc()

    {:ok, %{hub: hub, strategy: strategy}}
  end

  @impl true
  def handle_info(:schedule_scores_calc, state) do
    # Check if current node is the leader.
    if Elector.leader?() do
      nodes = Cluster.get_nodes(state.hub.storage.misc, [:include_local])
      caller = self()

      # Spawn a process on the remote nodes to
      for node <- nodes do
        Node.spawn(node, fn ->
          hub = ProcessHub.Coordinator.get_hub(state.hub.hub_id)
          dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())

          info = dist_strat.query_info_fn.(hub)
          Process.send(caller, {:calculate_score, node(), info})
        end)
      end

      # Reschedule the next calculation.
      schedule_scores_calc()
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:calculate_score, node, info}, state) do
    # Update the scoreboard with the new info from the node.
    node_score = state.strategy.calculate_score_fn.(state.hub, state.scoreboard, info)
    new_scoreboard = Map.put(state.scoreboard, node, node_score)

    {:noreply, %{state | scoreboard: new_scoreboard}}
  end

  # TODO:
  def default_query_info_fn(_hub), do: %{}

  # TODO:
  def default_calculate_score_fn(_hub, _scoreboard, _info), do: 0

  defp schedule_scores_calc() do
    # TODO: make the interval configurable.
    Process.send_after(self(), :schedule_scores_calc, 5_000)
  end
end

# TODO: document that only one hub in the cluster should be able to use the centralized scoreboard strategy at the same time.
# TODO: handle node leave/join.
