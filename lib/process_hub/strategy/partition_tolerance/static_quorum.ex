defmodule ProcessHub.Strategy.PartitionTolerance.StaticQuorum do
  @moduledoc """
  The static quorum strategy for partition tolerance is used when the `ProcessHub` cluster is
  concerned with partition failures, and the cluster size is known.

  When a node leaves or joins the `ProcessHub` cluster, the static quorum strategy will check if the
  quorum is present. If the quorum is not present, the `ProcessHub` will be considered in a network
  partition, and the distributed supervisor process of the `ProcessHub` will be terminated along with
  all the child processes.
  """

  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Service.State
  alias PrcoessHub.Service.Cluster

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
