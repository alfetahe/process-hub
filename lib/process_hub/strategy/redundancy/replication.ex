defmodule ProcessHub.Strategy.Redundancy.Replication do
  @moduledoc """
  The replication strategy allows for multiple instances of a process to be started
  across the cluster. The number of instances is determined by the `replication_factor`
  option.

  The replication strategy also comes with a `replication_model` option, which determines
  which instances of the process are active and which are passive.
  Imagine a scenario where you have a process that is responsible for handling streams of
  data. You may want to have multiple instances of this process running across the cluster,
  but only one of them should be active at any given time and insert data into the database.
  The passive instances of the process should be ready to take over if the active instance
  fails.

  This strategy also allows replication on all nodes in the cluster. This is done by setting
  the `replication_factor` option to `:cluster_size`.

  `ProcessHub` can notify the process when it is active or passive by sending a `:redundancy_signal`.

  > #### `Using the :redundancy_signal option` {: .info}
  > When using the `:redundancy_signal` option, make sure that the processes are handling
  > the message `{:process_hub, :redundancy_signal, mode}`, where the `mode` variable is either
  > `:active` or `:passive`.

  Example `GenServer` process handling the `:redundancy_signal`:
      def handle_info({:process_hub, :redundancy_signal, mode}, state) do
        # Update the state with the new mode and do something differently.
        {:noreply, Map.put(state, :replication_mode, mode)}
      end
  """

  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Utility.Name
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy

  @typedoc """
  Replication strategy options.

  - `replication_factor` - The number of instances of a single process across the cluster.
  This option can be positive integer or `cluster_size` atom to replicate process on all nodes.
  Default value is `2`.
  - `replication_model` - This option determines the mode in which the instances of processes are started.
  Default value is `:active_active`.
    - `:active_active` - All instances of a process across the cluster are equal.
    - `:active_passive` - Only one instance of a process across the cluster is active; the rest are passive.
      Remaining replicas are started as passive processes.
  - `redundancy_signal` - This option determines when a process should be notified of its replication mode.
  Default value is `:none`.
    - `:none` - No notifications are sent.
    - `:active_active` - Only active processes are notified.
    - `:active_passive` - Only passive processes are notified.
    - `:all` - All processes are notified.
  """
  @type t :: %__MODULE__{
          replication_factor: pos_integer() | :cluster_size,
          replication_model: :active_active | :active_passive,
          redundancy_signal: :none | :active | :passive | :all
        }

  defstruct replication_factor: 2, replication_model: :active_active, redundancy_signal: :none

  defimpl RedundancyStrategy, for: ProcessHub.Strategy.Redundancy.Replication do
    alias ProcessHub.Service.LocalStorage
    alias ProcessHub.Strategy.Redundancy.Replication

    @impl true
    @spec replication_factor(ProcessHub.Strategy.Redundancy.Replication.t()) ::
            pos_integer() | :cluster_size
    def replication_factor(strategy) do
      case strategy.replication_factor do
        :cluster_size ->
          Node.list() |> Enum.count()

        _ ->
          strategy.replication_factor
      end
    end

    @impl true
    @spec handle_post_start(
            ProcessHub.Strategy.Redundancy.Replication.t(),
            atom(),
            atom() | binary(),
            pid(),
            [node()]
          ) :: :ok
    def handle_post_start(%Replication{redundancy_signal: :none}, _, _, _, _), do: :ok

    def handle_post_start(strategy, _hub_id, _child_id, child_pid, child_nodes) do
      cond do
        strategy.replication_model === :active_passive ->
          # Start the process as passive if the current node is not the first node in the list.
          if List.first(child_nodes) !== node() &&
               Enum.member?([:passive, :all], strategy.redundancy_signal) do
            send_redundancy_signal(child_pid, :passive)
          end

          # Start the process as active if the current node is the first node in the list.
          if List.first(child_nodes) === node() &&
               Enum.member?([:active, :all], strategy.redundancy_signal) do
            send_redundancy_signal(child_pid, :active)
          end

        strategy.replication_model === :active_active ->
          if Enum.member?([:active, :all], strategy.redundancy_signal) do
            send_redundancy_signal(child_pid, :passive)
          end

        true ->
          nil
      end

      :ok
    end

    @impl true
    @spec handle_post_update(
            ProcessHub.Strategy.Redundancy.Replication.t(),
            ProcessHub.hub_id(),
            atom() | binary(),
            [node()],
            {:up | :down, node()}
          ) :: :ok
    def handle_post_update(%Replication{redundancy_signal: :none}, _, _, _, _), do: :ok

    def handle_post_update(
          %Replication{replication_model: :active_passive} = strategy,
          hub_id,
          child_id,
          [active_node | _] = nodes,
          {:up, node}
        ) do
      local_node = node()

      cond do
        active_node === local_node ->
          # Do nothing because the current node still holds the active process.
          :ok

        strategy.redundancy_signal === :active ->
          # Do nothing because current node can't be active at this point.
          :ok

        true ->
          # Check if the current node was the last active node.
          prev_active = Enum.filter(nodes, &(&1 !== node)) |> List.first()

          if prev_active === local_node do
            # New mode is :passive at this point.
            child_pid(hub_id, child_id) |> send_redundancy_signal(:passive)
          end
      end
    end

    def handle_post_update(
          %Replication{replication_model: :active_passive} = strategy,
          hub_id,
          child_id,
          [active_node | _] = nodes,
          {:down, node}
        ) do
      local_node = node()
      prev_active = prev_mode(hub_id, child_id, [node | nodes], strategy)

      cond do
        prev_active === local_node && active_node !== local_node ->
          if Enum.member?([:passive, :all], strategy.redundancy_signal) do
            # Current node held the active process but no longer and is now passive.
            child_pid(hub_id, child_id) |> send_redundancy_signal(:passive)
          end

        prev_active !== local_node && active_node === local_node ->
          if Enum.member?([:active, :all], strategy.redundancy_signal) do
            # Current node held passive process but now holds the active process.
            child_pid(hub_id, child_id) |> send_redundancy_signal(:active)
          end
      end
    end

    def handle_post_update(_, _, _, _, _), do: :ok

    defp child_pid(hub_id, child_id) do
      Name.distributed_supervisor(hub_id)
      |> DistributedSupervisor.local_pid(child_id)
    end

    defp prev_mode(hub_id, child_id, nodes, strategy) do
      Name.local_storage(hub_id)
      |> LocalStorage.get(:distribution_strategy)
      |> DistributionStrategy.belongs_to(hub_id, child_id, nodes, replication_factor(strategy))
      |> List.first()
    end

    defp send_redundancy_signal(pid, mode) do
      send(pid, {:process_hub, :redundancy_signal, mode})
    end
  end
end
