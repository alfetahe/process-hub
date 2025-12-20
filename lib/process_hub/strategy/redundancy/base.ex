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
  Handles redundancy when nodes join the cluster.

  The strategy receives the full registry data and nodes that joined,
  and decides internally what replication actions to take:
  - Start replicas locally if needed
  - Stop replicas locally if needed
  - Send mode signals (active/passive transitions) for replication strategy

  ## Parameters
  - `strategy` - the redundancy strategy struct
  - `hub` - the hub state
  - `registry_data` - full dump from ProcessRegistry.dump()
  - `nodes` - list of nodes that triggered redistribution
  """
  @spec handle_redundancy(struct(), Hub.t(), registry_data :: list(), nodes :: [node()]) ::
          :ok
  def handle_redundancy(strategy, hub, registry_data, nodes)
end
