defprotocol ProcessHub.Strategy.Synchronization.Base do
  @moduledoc """
  This protocol defines the behavior of a synchronization strategy.
  """

  @doc """
  Triggered when coordinator is initialized.

  Could be used to perform initialization.
  """
  @spec init(struct(), ProcessHub.hub_id()) :: any()
  def init(strategy, hub_id)

  @doc """
  This function is called when a process has been started on the local node, and the
  information about the process is about to be propagated to other nodes.
  """
  @spec propagate(__MODULE__.t(), ProcessHub.hub_id(), [term()], node(), :add | :rem, keyword()) ::
          :ok
  def propagate(strategy, hub_id, children, node, type, opts)

  @doc """
  This function handles the propagation messages sent by `ProcessHub.Strategy.Synchronization.Base.propagate/6`.

  It saves the process data that was propagated to the local process registry.
  """
  @spec handle_propagation(__MODULE__.t(), ProcessHub.hub_id(), term(), :add | :rem) :: :ok
  def handle_propagation(strategy, hub_id, propagation_data, type)

  @doc """
  Initializes the periodic synchronization of the process registry.
  """
  @spec init_sync(__MODULE__.t(), ProcessHub.hub_id(), [node()]) :: :ok
  def init_sync(strategy, hub_id, cluster_nodes)

  @doc """
  Handles the periodic synchronization of the process registry.
  """
  @spec handle_synchronization(__MODULE__.t(), ProcessHub.hub_id(), term(), node()) :: :ok
  def handle_synchronization(strategy, hub_id, remote_data, remote_node)
end
