defmodule ProcessHub.Strategy.PartitionTolerance.DynamicQuorum do
  @moduledoc """
  The dynamic quorum strategy provides a dynamic way to handle network partitions in the `ProcessHub` cluster.

  This strategy is suitable for clusters that do not know the number of nodes in the cluster beforehand.

  The dynamic quorum strategy uses a cache to store the quorum log. The quorum log is a list of tuples
  containing the node name and the timestamp when the connection to the node was lost.
  This log is used to calculate the quorum size, which is measured in percentage.
  If the calculated quorum size is less than the `quorum_size` defined in the configuration,
  the `ProcessHub` will be considered to be in a network partition.
  In such a case, the `ProcessHub` will terminate its distributed supervisor process,
  `ProcessHub.DistributedSupervisor`, and all its children. Also, the local event queue will be
  locked by increasing the priority level.

  The quorum size is calculated by the following formula:

      quorum_size = (connected_nodes / (connected_nodes + down_nodes)) * 100

      # The `connected_nodes` are the number of nodes that are currently connected to the `ProcessHub` cluster.
      # The `down_nodes` are the number of nodes that are listed under the quorum log.

  The `threshold_time` is used to determine how long a node should be listed in the quorum log
  before it is removed from the quorum log. This means if we have a `threshold_time` of 10 seconds,
  and we lose one node every 10 seconds until we have lost all nodes, the system won't be
  considered to be in a network partition, regardless of whether the lost nodes are lost due to network
  partition or not. If we lose all those nodes in less than 10 seconds, the system will be considered
  to be in a network partition.

  > #### `Scaling down` {: .error}
  > When scaling down the cluster, make sure to scale down one node at a time
  > and wait for the `threshold_time` before scaling down the next node.
  >
  > Do not scale down too many nodes at once because the system may think that it is in a network partition
  > and terminate the `ProcessHub.DistributedSupervisor` process and all its children.
  """

  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Constant.StorageKey

  @typedoc """
  Dynamic quorum strategy configuration.

  - `quorum_size` - The quorum size is measured in percentage. This is the required quorum size.
  For example, `50` means that if we have 10 nodes in the cluster, the system will be
  considered to be in a network partition if we lose 6 (60% of the cluster) nodes or more within
  the `threshold_time` period.
  - `threshold_time` - The threshold time is measured in seconds. This is how long a node should be
  listed in the quorum log before it is removed from the quorum log.
  """
  @type t :: %__MODULE__{
          quorum_size: non_neg_integer(),
          threshold_time: non_neg_integer()
        }
  @enforce_keys [:quorum_size]
  defstruct [:quorum_size, threshold_time: 30]

  defimpl PartitionToleranceStrategy, for: ProcessHub.Strategy.PartitionTolerance.DynamicQuorum do
    @impl true
    def init(_strategy, _hub), do: nil

    @impl true
    def toggle_unlock?(strategy, hub, up_node) do
      cluster_nodes = Cluster.nodes(hub.storage.misc, [:include_local])

      node_log_func(strategy, hub, up_node, :up)
      propagate_quorum_log(hub, up_node)

      !quorum_failure?(strategy, cluster_nodes, hub.storage.misc)
    end

    @impl true
    def toggle_lock?(strategy, hub, down_node) do
      cluster_nodes = Cluster.nodes(hub.storage.misc, [:include_local])
      node_log_func(strategy, hub, down_node, :down)

      quorum_failure?(strategy, cluster_nodes, hub.storage.misc)
    end

    defp propagate_quorum_log(hub, node) do
      local_log =
        case Storage.get(hub.storage.misc, StorageKey.dqdn()) do
          nil -> []
          data -> data
        end

      GenServer.cast(
        {hub.hub_id, node},
        {:exec_cast,
         {
           ProcessHub.Strategy.PartitionTolerance.DynamicQuorum,
           :sync_quorum_log,
           [local_log]
         }}
      )
    end

    defp quorum_failure?(strategy, cluster_nodes, misc_storage) do
      connected_nodes = length(cluster_nodes)

      cached_data =
        case Storage.get(misc_storage, StorageKey.dqdn()) do
          nil -> []
          data -> data
        end

      down_nodes = length(cached_data)

      lost_quorum = down_nodes / (connected_nodes + down_nodes) * 100
      quorum_left = 100 - lost_quorum

      quorum_left < strategy.quorum_size
    end

    defp node_log_func(strategy, hub, node, type) do
      new_data = node_log_data(hub, node, strategy.threshold_time, type)

      Storage.insert(hub.storage.misc, StorageKey.dqdn(), new_data)
    end

    defp node_log_data(hub, node, threshold_time, :up) do
      timestamp = DateTime.utc_now() |> DateTime.to_unix(:second)
      threshold_time = timestamp - threshold_time

      case Storage.get(hub.storage.misc, StorageKey.dqdn()) do
        nil ->
          []

        data ->
          # Remove rows older than threshold_time and the same node
          Enum.filter(data, fn {cache_node, time} ->
            time > threshold_time && cache_node != node
          end)
      end
    end

    defp node_log_data(hub, node, threshold_time, :down) do
      timestamp = DateTime.utc_now() |> DateTime.to_unix(:second)
      threshold_time = timestamp - threshold_time

      case Storage.get(hub.storage.misc, StorageKey.dqdn()) do
        nil ->
          [{node, timestamp}]

        data ->
          # Remove rows older than threshold_time and the same node
          filtered_data =
            Enum.filter(data, fn {cache_node, time} ->
              time > threshold_time && cache_node != node
            end)

          # Add a new row.
          [{node, timestamp} | filtered_data]
      end
    end
  end

  def sync_quorum_log(hub, remote_log) do
    local_log =
      case Storage.get(hub.storage.misc, StorageKey.dqdn()) do
        nil -> []
        local_log -> local_log
      end

    if length(remote_log) > length(local_log) do
      # Overwrite quorum log with other nodes data that has more information in it.
      Storage.insert(hub.storage.misc, StorageKey.dqdn(), remote_log)
    end
  end
end
