defprotocol ProcessHub.Strategy.Synchronization.Base do
  alias ProcessHub.Request.NodeRequest
  alias ProcessHub.Hub

  @moduledoc """
  This protocol defines the behavior of a synchronization strategy.
  """

  @doc """
  Triggered when coordinator is initialized.

  Could be used to perform initialization.
  """
  @spec init(struct(), Hub.t()) :: struct()
  def init(strategy, hub)

  @doc """
  Propagates a request to other nodes in the cluster.
  """
  @spec propagate(
          __MODULE__.t(),
          Hub.t(),
          NodeRequest.t(),
          keyword()
        ) :: :ok
  def propagate(strategy, hub, request, opts)

  @doc """
  Initializes the periodic synchronization of the process registry.
  """
  @spec init_sync(__MODULE__.t(), Hub.t(), [node()]) :: :ok
  def init_sync(strategy, hub, cluster_nodes)

  @doc """
  Handles the periodic synchronization of the process registry.
  """
  @spec handle_synchronization(__MODULE__.t(), Hub.t(), term(), node()) :: :ok
  def handle_synchronization(strategy, hub, remote_data, remote_node)

  @doc """
  Broadcasts local registry data to target nodes when they join the cluster.
  Called after nodes are added to the cluster state.
  """
  @spec broadcast_local_data(
          __MODULE__.t(),
          Hub.t(),
          [{ProcessHub.child_spec(), pid(), ProcessHub.child_metadata()}],
          [node()]
        ) :: :ok
  def broadcast_local_data(strategy, hub, local_data, target_nodes)

  @doc """
  Handles received node join data and stores it in the local registry.
  Called when another node broadcasts its registry data to us.
  """
  @spec handle_node_join_data(__MODULE__.t(), Hub.t(), term(), node()) :: :ok
  def handle_node_join_data(strategy, hub, remote_data, remote_node)
end
