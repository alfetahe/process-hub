defmodule ProcessHub.Strategy.PartitionTolerance.MajorityQuorum do
  @moduledoc """
  The majority quorum strategy provides automatic partition tolerance that adapts to cluster size.

  This strategy is ideal for clusters that:
  - Start with a single node (development or initial deployment)
  - Scale up over time
  - Need proper split-brain protection once established
  - Want to avoid manual quorum configuration

  ## How It Works

  The majority quorum strategy tracks the maximum cluster size ever seen and requires
  a majority of those nodes to be present for the cluster to operate.

  The quorum is calculated as: `floor(max_cluster_size / 2) + 1`

  ### Example Progression

      1 node  → quorum = 1 (can operate)
      2 nodes → quorum = 2 (both needed)
      3 nodes → quorum = 2 (majority)
      5 nodes → quorum = 3 (majority)

  ### Split-Brain Protection

  If a 5-node cluster splits into partitions of 3 and 2 nodes:
  - The partition with 3 nodes maintains quorum and continues operating
  - The partition with 2 nodes loses quorum and enters partition mode
    (distributed supervisor and all children are terminated)

  ## Configuration

      partition_tolerance_strategy: %ProcessHub.Strategy.PartitionTolerance.MajorityQuorum{
        initial_cluster_size: 1,  # Default: 1 (works with single node)
        track_max_size: true      # Default: true (adapts to cluster growth)
      }

  ## Intentional Downsizing

  > #### Scaling Down Requires Manual Intervention {: .warning}
  > MajorityQuorum does **not** automatically handle cluster scale-down. The strategy remembers
  > the maximum cluster size to protect against split-brain scenarios. If you scale down nodes
  > (e.g., from 5 to 3 nodes), the cluster will still require a majority of the original 5 nodes
  > (i.e., 3 nodes) to operate.
  >
  > For automatic adaptation to gradual scale-down, consider using
  > `ProcessHub.Strategy.PartitionTolerance.DynamicQuorum` instead.

  If you intentionally downsize your cluster (e.g., from 5 nodes to 3 nodes), you'll need
  to reset the expected cluster size, otherwise the cluster will require 3 nodes (majority of 5)
  to operate.

  You can reset the expected cluster size using:

      ProcessHub.Strategy.PartitionTolerance.MajorityQuorum.reset_cluster_size(:my_hub, 3)

  ## Options

  - `initial_cluster_size` - The initial expected cluster size. Default: `1`.
    Used as the starting point for quorum calculation until a larger cluster is seen.

  - `track_max_size` - Whether to automatically track and remember the maximum cluster
    size ever seen. Default: `true`. If set to `false`, the quorum will always be
    calculated based on `initial_cluster_size`.
  """

  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Constant.StorageKey

  @typedoc """
  Majority quorum strategy configuration.

  - `initial_cluster_size` - The initial expected cluster size. Used as the starting point
    for quorum calculation. Default: `1` (supports single-node startup).
  - `track_max_size` - Whether to automatically track and remember the maximum cluster size
    ever seen. Default: `true`.
  """
  @type t() :: %__MODULE__{
          initial_cluster_size: pos_integer(),
          track_max_size: boolean()
        }

  defstruct initial_cluster_size: 1, track_max_size: true

  @doc """
  Resets the expected cluster size for a ProcessHub instance.

  This is useful when intentionally downsizing your cluster. Without resetting,
  the cluster will continue to require a majority of the maximum size ever seen.

  ## Parameters

  - `hub_id` - The ProcessHub instance ID
  - `new_size` - The new expected cluster size

  ## Example

      # After downsizing from 5 nodes to 3 nodes
      ProcessHub.Strategy.PartitionTolerance.MajorityQuorum.reset_cluster_size(:my_hub, 3)

  This will update the maximum seen cluster size to 3, so the cluster will now
  require a majority of 3 (i.e., 2 nodes) instead of a majority of 5 (i.e., 3 nodes).
  """
  @spec reset_cluster_size(atom(), pos_integer()) :: :ok | {:error, term()}
  def reset_cluster_size(hub_id, new_size)
      when is_atom(hub_id) and is_integer(new_size) and new_size > 0 do
    # Get the coordinator PID for the hub
    case ProcessHub.Coordinator.get_hub(hub_id) do
      %{storage: %{misc: misc_storage}} ->
        Storage.insert(misc_storage, StorageKey.mqms(), new_size)
        :ok

      nil ->
        {:error, :hub_not_found}
    end
  rescue
    e ->
      {:error, e}
  end

  defimpl PartitionToleranceStrategy, for: ProcessHub.Strategy.PartitionTolerance.MajorityQuorum do
    alias ProcessHub.Service.Cluster
    alias ProcessHub.Service.Storage
    alias ProcessHub.Constant.StorageKey

    @impl true
    def init(strategy, hub) do
      cluster_nodes = Cluster.nodes(hub.storage.misc, [:include_local])
      current_size = length(cluster_nodes)

      # Initialize max_seen with the larger of initial_cluster_size or current size
      max_seen = max(strategy.initial_cluster_size, current_size)
      Storage.insert(hub.storage.misc, StorageKey.mqms(), max_seen)

      strategy
    end

    @impl true
    def toggle_unlock?(strategy, hub, _up_node) do
      cluster_nodes = Cluster.nodes(hub.storage.misc, [:include_local])
      current_size = length(cluster_nodes)

      # Update max_seen if tracking is enabled and cluster grew
      if strategy.track_max_size do
        max_seen =
          Storage.get(hub.storage.misc, StorageKey.mqms()) || strategy.initial_cluster_size

        new_max = max(max_seen, current_size)

        if new_max > max_seen do
          Storage.insert(hub.storage.misc, StorageKey.mqms(), new_max)
        end
      end

      # Check if we have majority
      max_seen = Storage.get(hub.storage.misc, StorageKey.mqms()) || strategy.initial_cluster_size
      has_majority?(current_size, max_seen)
    end

    @impl true
    def toggle_lock?(strategy, hub, _down_node) do
      cluster_nodes = Cluster.nodes(hub.storage.misc, [:include_local])
      current_size = length(cluster_nodes)

      max_seen = Storage.get(hub.storage.misc, StorageKey.mqms()) || strategy.initial_cluster_size
      !has_majority?(current_size, max_seen)
    end

    # Calculate if current cluster size meets majority requirement
    defp has_majority?(current_size, max_seen) do
      required = div(max_seen, 2) + 1
      current_size >= required
    end
  end
end
