defprotocol ProcessHub.Strategy.Distribution.Base do
  alias ProcessHub.Hub

  @moduledoc """
  The distribution strategy protocol defines behaviour to identify the nodes
  which are responsible for a child process.
  """

  @doc """
  Triggered when coordinator is initialized.

  Could be used to perform initialization.
  """
  @spec init(struct(), Hub.t()) :: struct()
  def init(strategy, hub)

  @doc """
  Returns the list of nodes where the child process belongs to.

  The list of nodes is used to determine where the child process should be started
  or migrated to.
  """
  @spec belongs_to(
          strategy :: struct(),
          hub :: Hub.t(),
          child_ids :: [ProcessHub.child_id()],
          replication_factor :: pos_integer()
        ) :: [{ProcessHub.child_id(), [node()]}]
  def belongs_to(strategy, hub, child_ids, replication_factor)

  @doc """
  Perform any necessary initialization and validation for the started children.
  """
  @spec children_init(struct(), Hub.t(), [map()], keyword()) :: :ok | {:error, any()}
  def children_init(strategy, hub, child_specs, opts)
end
