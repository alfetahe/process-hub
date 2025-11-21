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

  # TODO:
  @doc """
  Triggered when a new node is added to the cluster.
  Can perform actions such as starting new replicas on the added node.
  """
  def handle_node_up(strategy, hub, added_node, children_data)

    # TODO:
  @doc """
  Triggered when a new node is added to the cluster.
  Can perform actions such as starting new replicas on the added node.
  """
  def handle_node_down(strategy, hub, removed_node, children_data)
end
