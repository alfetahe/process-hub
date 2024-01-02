defprotocol ProcessHub.Strategy.Distribution.Base do
  @moduledoc """
  The distribution strategy protocol provides API functions for distributing child processes.
  """

  @spec belongs_to(
          strategy :: struct(),
          hub_id :: atom(),
          child_id :: atom() | binary(),
          replication_factor :: pos_integer()
        ) :: [node()]
  def belongs_to(strategy, hub_id, child_id, replication_factor)

  @doc """
  Triggered when coordinator is initialized and lets the strategy update it's state.
  """
  @spec init(strategy :: struct(), hub_id :: atom(), hub_nodes :: [node()]) :: any()
  def init(strategy, hub_id, hub_nodes)

  @doc """
  Triggered when children are started and lets the strategy
  """
  @spec children_init(struct(), atom(), [map()], keyword()) :: :ok | {:error, any()}
  def children_init(strategy, hub_id, child_specs, opts)

  @doc """
  Triggered when node joins the cluster and lets the strategy update it's state.

  Do not start/stop any processes here.
  """
  @spec node_join(struct(), atom(), [node()], node()) :: any()
  def node_join(strategy, hub_id, hub_nodes, node)

  @doc """
  Triggered when node leaves the cluster and lets the strategy update it's state.

  Do not start/stop any processes here.
  """
  @spec node_leave(struct(), atom(), [node()], node()) :: any()
  def node_leave(strategy, hub_id, hub_nodes, node)
end
