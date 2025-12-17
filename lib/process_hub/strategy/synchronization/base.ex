defprotocol ProcessHub.Strategy.Synchronization.Base do
  alias ProcessHub.Handler.ChildrenAdd.PostStartData
  alias ProcessHub.Handler.ChildrenRem.StopHandle
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
  This function is called when a process has been started on the local node, and the
  information about the process is about to be propagated to other nodes.
  """
  @spec propagate(
          __MODULE__.t(),
          Hub.t(),
          [PostStartData.t() | StopHandle.t()],
          node(),
          :add | :rem,
          keyword()
        ) ::
          :ok
  def propagate(strategy, hub, children, node, type, opts)

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
