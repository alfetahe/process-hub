defprotocol ProcessHub.Strategy.Redundancy.Base do
  alias ProcessHub.Hub

  @moduledoc """
  The redundancy protocol relies on the `HashRing` library to distribute processes across
  the cluster and determine which node should be responsible for a given process by its `child_id` key.

  It is possible to start the same process on multiple nodes in the cluster.
  """

  @doc """
  Triggered when coordinator is initialized.

  Could be used to perform initialization.
  """
  @spec init(struct(), Hub.t()) :: struct()
  def init(strategy, hub)

  @doc """
  Returns the replication factor for the given strategy struct. This is the number of replicas
  that the process will be started with.
  """
  @spec replication_factor(struct()) :: pos_integer()
  def replication_factor(strategy)

  @doc """
  Returns the master node that the given `child_id` belongs to.
  """
  @spec master_node(struct(), Hub.t(), ProcessHub.child_id(), [node()]) :: node()
  def master_node(strategy, hub, child_id, child_nodes)

  @doc """
  Handles redundancy when nodes join or leave the cluster.

  For Replication strategy:
  - Starts/stops replicas locally (indices 1+ from calculated_cids)
  - Sends mode signals (active/passive transitions)

  Note: Primary process starting/stopping is handled by migration strategy.

  ## Parameters
  - `strategy` - the redundancy strategy struct
  - `hub` - the hub state
  - `calculated_cids` - map of child_id => [node()] from migration strategy.
                        Index 0 = primary, indices 1+ = replicas
  - `nodes` - list of nodes that triggered redistribution
  """
  @spec handle_redundancy(
          struct(),
          Hub.t(),
          calculated_cids :: %{ProcessHub.child_id() => [node()]},
          nodes :: [node()]
        ) :: :ok
  def handle_redundancy(strategy, hub, calculated_cids, nodes)
end
