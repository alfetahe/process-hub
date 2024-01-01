defmodule ProcessHub.Strategy.Distribution.Guided do
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy

  @type t() :: %__MODULE__{}
  defstruct []

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.Guided do
    @impl true
    @spec belongs_to(
            ProcessHub.Strategy.Distribution.Guided.t(),
            atom(),
            atom() | binary(),
            pos_integer()
          ) :: [atom]
    def belongs_to(_strategy, hub_id, child_id, replication_factor) do
    end

    @impl true
    def init(_strategy, hub_id, hub_nodes) do
    end

    @impl true
    @spec node_join(struct(), atom(), [node()], node()) :: any()
    def node_join(_strategy, hub_id, _hub_nodes, node) do
    end

    @impl true
    @spec node_leave(struct(), atom(), [node()], node()) :: any()
    def node_leave(_strategy, hub_id, _hub_nodes, node) do
    end
  end
end
