defprotocol ProcessHub.Strategy.Migration.Base do
  alias ProcessHub.Hub

  @moduledoc """
  The migration strategy protocol provides API functions for migrating child processes.
  """

  @doc """
  Triggered when coordinator is initialized.

  Could be used to perform initialization.
  """
  @spec init(struct(), Hub.t()) :: struct()
  def init(strategy, hub)

  @doc """
  Handles migration when nodes join the cluster (topology expansion).

  Called from NodeUp handler to redistribute processes to newly joined nodes.
  Each strategy implementation handles its own logic for migrating processes
  that should now be on the new nodes.

  ## Parameters
  - `struct` - the strategy struct
  - `hub` - the hub state
  - `nodes` - list of nodes that have joined the cluster
  - `handler` - the NodeUp handler struct

  ## Returns
  Updated handler struct with any additional data computed during processing.
  """
  @spec handle_topology_expansion(
          struct :: __MODULE__.t(),
          hub :: Hub.t(),
          nodes :: [node()],
          handler :: ProcessHub.Task.ClusterUpdateTask.NodeUp.t()
        ) :: ProcessHub.Task.ClusterUpdateTask.NodeUp.t()
  def handle_topology_expansion(struct, hub, nodes, handler)

  @doc """
  Handles migration when nodes leave the cluster (topology contraction).

  Called from NodeDown handler to redistribute processes from removed nodes.
  Each strategy implementation handles its own logic for starting processes
  that should now be on the local node.

  ## Parameters
  - `struct` - the strategy struct
  - `hub` - the hub state
  - `removed_nodes` - list of nodes that have left the cluster
  - `handler` - the NodeDown handler struct

  ## Returns
  Updated handler struct with any additional data computed during processing.
  """
  @spec handle_topology_contraction(
          struct :: __MODULE__.t(),
          hub :: Hub.t(),
          removed_nodes :: [node()],
          handler :: ProcessHub.Task.ClusterUpdateTask.NodeDown.t()
        ) :: ProcessHub.Task.ClusterUpdateTask.NodeDown.t()
  def handle_topology_contraction(struct, hub, removed_nodes, handler)
end
