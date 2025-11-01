defmodule ProcessHub.Strategy.PartitionTolerance.StaticQuorum do
  @moduledoc """
  The static quorum strategy provides partition tolerance through a fixed minimum node count.

  This strategy is ideal for clusters that:
  - Have a known, fixed cluster size
  - Need explicit control over partition behavior
  - Do not dynamically scale up or down
  - Require predictable quorum requirements

  ## How It Works

  The static quorum strategy requires a minimum number of nodes (`:quorum_size`) to be
  present in the cluster for it to operate. When the number of nodes falls below this
  threshold, the cluster enters partition mode and terminates the distributed supervisor
  along with all child processes.

  ### Behavior on Node Changes

  **Node leaves cluster:**
  - If remaining nodes >= `:quorum_size`: cluster continues operating
  - If remaining nodes < `:quorum_size`: cluster enters partition mode

  **Node joins cluster:**
  - If total nodes >= `:quorum_size`: cluster exits partition mode (if it was in one)
  - If total nodes < `:quorum_size`: cluster remains in partition mode

  ### Split-Brain Protection

  If you have a 5-node cluster with `quorum_size: 3` and it splits into partitions of 3 and 2:
  - The partition with 3 nodes maintains quorum and continues operating
  - The partition with 2 nodes loses quorum and enters partition mode

  ## Configuration

      partition_tolerance_strategy: %ProcessHub.Strategy.PartitionTolerance.StaticQuorum{
        quorum_size: 3,           # Required: minimum nodes needed
        startup_confirm: false    # Optional: check quorum at startup (default: false)
      }

  ## Options

  - `quorum_size` - **Required**. The minimum number of nodes that must be present in the
    cluster for it to operate. Must be a positive integer.

  - `startup_confirm` - Optional. If set to `true`, the hub will check if quorum is met
    when starting up. If quorum is not met at startup, the cluster immediately enters
    partition mode. Default: `false` (allows startup with any number of nodes).

  ## Important Considerations

  ### Startup Behavior

  With `startup_confirm: false` (default):
  - The cluster starts regardless of current node count
  - Partition checking begins when nodes join or leave
  - This allows starting nodes before the full cluster is formed

  With `startup_confirm: true`:
  - The cluster immediately enters partition mode if current nodes < quorum_size
  - Use this when you want strict quorum enforcement from the start

  ### Scaling Considerations

  This strategy is **not suitable** for clusters that scale dynamically. If your cluster
  size changes over time, consider using:
  - `ProcessHub.Strategy.PartitionTolerance.MajorityQuorum` for automatic adaptation
  - `ProcessHub.Strategy.PartitionTolerance.DynamicQuorum` for time-based adaptation
  """

  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Service.State
  alias ProcessHub.Service.Cluster

  @typedoc """
  Static quorum strategy configuration.

  - `quorum_size` - The quorum size is measured in the number of nodes. For example, `3` means that
    there should be at least 3 nodes in the cluster for the `ProcessHub` to be considered healthy.
  - `startup_confirm` - If set to `true`, the `ProcessHub` will check if the quorum is present
    when the `ProcessHub` is starting up. If the quorum is not present, it will be
    considered as a network partition. The default value is `false`.
  """
  @type t() :: %__MODULE__{
          quorum_size: non_neg_integer(),
          startup_confirm: boolean()
        }
  @enforce_keys [:quorum_size]
  defstruct [:quorum_size, startup_confirm: false]

  defimpl PartitionToleranceStrategy, for: ProcessHub.Strategy.PartitionTolerance.StaticQuorum do
    alias ProcessHub.Service.Cluster

    @impl true
    def init(strategy, hub) do
      cluster_nodes = Cluster.nodes(hub.storage.misc, [:include_local])

      if strategy.startup_confirm do
        unless quorum_present?(strategy, cluster_nodes) do
          State.toggle_quorum_failure(hub)
        end
      end

      strategy
    end

    @impl true
    def toggle_lock?(strategy, hub, _down_node) do
      cluster_nodes = Cluster.nodes(hub.storage.misc, [:include_local])

      !quorum_present?(strategy, cluster_nodes)
    end

    @impl true
    def toggle_unlock?(strategy, hub, _up_node) do
      cluster_nodes = Cluster.nodes(hub.storage.misc, [:include_local])

      quorum_present?(strategy, cluster_nodes)
    end

    defp quorum_present?(strategy, cluster_nodes) do
      strategy.quorum_size <= length(cluster_nodes)
    end
  end
end
