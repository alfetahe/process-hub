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
  Returns a map of child_id to list of nodes where the child process belongs to.

  The map is used to determine where the child process should be started
  or migrated to.
  """
  @spec belongs_to(
          strategy :: struct(),
          hub :: Hub.t(),
          child_ids :: [ProcessHub.child_id()],
          replication_factor :: pos_integer()
        ) :: %{ProcessHub.child_id() => [node()]}
  def belongs_to(strategy, hub, child_ids, replication_factor)

  @doc """
  Perform any necessary initialization and validation for the started children.
  """
  @spec children_init(struct(), Hub.t(), [map()], keyword()) :: :ok | {:error, any()}
  def children_init(strategy, hub, child_specs, opts)

  @doc """
  Returns whether this distribution strategy produces deterministic results
  based solely on the node topology.

  Deterministic strategies (like ConsistentHashing) always produce the same
  distribution for the same set of nodes. Non-deterministic strategies
  (like CentralizedLoadBalancer) may produce different distributions based
  on runtime factors like node load.

  This is used to optimize child validation - deterministic strategies can
  skip revalidation when topology signature matches.
  """
  @spec deterministic?(struct()) :: boolean()
  def deterministic?(strategy)

  @doc """
  Computes a distribution signature based on the current state that affects distribution.

  For deterministic strategies (like ConsistentHashing), this is typically based on
  the sorted list of cluster nodes. For non-deterministic strategies (like
  CentralizedLoadBalancer), this may include additional state like load scores.

  Used to detect if distribution-relevant state has changed between request creation
  and execution.

  Returns an integer hash that uniquely identifies the current distribution state.
  """
  @spec distribution_signature(struct(), Hub.t()) :: non_neg_integer()
  def distribution_signature(strategy, hub)
end
