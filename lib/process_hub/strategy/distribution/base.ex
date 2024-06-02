defprotocol ProcessHub.Strategy.Distribution.Base do
  @moduledoc """
  The distribution strategy protocol defines behaviour to identify the nodes
  which are responsible for a child process.
  """

  @doc """
  Triggered when coordinator is initialized.

  Could be used to perform initialization.
  """
  @spec init(struct(), ProcessHub.hub_id()) :: any()
  def init(strategy, hub_id)

  @doc """
  Returns the list of nodes where the child process belongs to.

  The list of nodes is used to determine where the child process should be started
  or migrated to.
  """
  @spec belongs_to(
          strategy :: struct(),
          hub_id :: ProcessHub.hub_id(),
          child_id :: atom() | binary(),
          replication_factor :: pos_integer()
        ) :: [node()]
  def belongs_to(strategy, hub_id, child_id, replication_factor)

  @doc """
  Perform any necessary initialization and validation for the started children.
  """
  @spec children_init(struct(), ProcessHub.hub_id(), [map()], keyword()) :: :ok | {:error, any()}
  def children_init(strategy, hub_id, child_specs, opts)
end
