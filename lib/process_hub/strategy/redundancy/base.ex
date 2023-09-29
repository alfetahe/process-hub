defprotocol ProcessHub.Strategy.Redundancy.Base do
  @moduledoc """
  The redundancy protocol relies on the `HashRing` library to distribute processes across
  the cluster and determine which node should be responsible for a given process by its `child_id` key.

  It is possible to start the same process on multiple nodes in the cluster.
  """

  alias :hash_ring, as: HashRing

  @doc """
  Returns the replication factor for the given strategy struct. This is the number of replicas
  that the process will be started with.
  """
  @spec replication_factor(strategy_struct :: struct()) :: pos_integer()
  def replication_factor(struct)

  @doc """
  Determines the nodes that are responsible for the given `child_id` (process).
  """
  @spec belongs_to(struct(), HashRing.t(), atom() | binary()) :: [node()]
  def belongs_to(struct, hash_ring, child_id)

  @doc """
  This function is called when `ProcessHub.DistributedSupervisor` has started a new
  child process, and the strategy can perform any post-start actions.
  """
  @spec handle_post_start(struct(), HashRing.t(), atom() | binary(), pid()) :: :ok
  def handle_post_start(struct, hash_ring, child_id, child_pid)

  @doc """
  This function is called when `ProcessHub.DistributedSupervisor` has started a
  replica of a child process, and the strategy can perform any post-update actions.
  """
  @spec handle_post_update(struct(), atom(), atom() | binary(), any()) :: :ok
  def handle_post_update(struct, hub_id, child_id, data)
end
