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
  alias ProcessHub.Service.Ring
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
            struct(),
            atom() | binary(),
            pid(),
            [node()]
          ) :: :ok
    def handle_post_start(strategy, distribution_strategy, child_id, child_pid, hub_nodes) do
      nodes =
        DistributionStrategy.belongs_to(
          distribution_strategy,
          child_id,
          hub_nodes,
          replication_factor(strategy)
        )

      child_mode = child_mode(strategy, nodes)
      notify = redundancy_signal?(strategy.redundancy_signal, child_mode)

      if notify do
        send_redundancy_signal(child_pid, child_mode)
      end

      :ok
    end

    # TODO: hash ring needs to be taken out
    @impl true
    @spec handle_post_update(
            ProcessHub.Strategy.Redundancy.Replication.t(),
            ProcessHub.hub_id(),
            atom() | binary()
          ) :: :ok
    def handle_post_update(
          strategy,
          hub_id,
          child_id
        ) do
      replication_factor = replication_factor(strategy)
      # TODO: check from local registry the order and do not use the hash ring at all
      # old_mode = process_redun_mode(strategy, child_id, old_hash_ring, replication_factor)
      # new_mode = process_redun_mode(strategy, child_id, hash_ring, replication_factor)

      child_pid = DistributedSupervisor.local_pid(Name.distributed_supervisor(hub_id), child_id)
      notify = redundancy_signal?(strategy.redundancy_signal, new_mode)

      if notify && old_mode !== new_mode && is_pid(child_pid) do
        send_redundancy_signal(child_pid, new_mode)
      end

      :ok
    end

    defp process_redun_mode(strategy, child_id, hash_ring, replication_factor) do
      child_nodes = Ring.key_to_nodes(hash_ring, child_id, replication_factor)
      child_mode(strategy, child_nodes)
    end

    defp child_mode(strategy, child_nodes) do
      case strategy.replication_model do
        :active_active ->
          :active

        :active_passive ->
          if List.first(child_nodes) === node(), do: :active, else: :passive
      end
    end

    defp send_redundancy_signal(pid, mode) do
      send(pid, {:process_hub, :redundancy_signal, mode})
    end

    defp redundancy_signal?(redundancy_signal, process_mode) do
      case redundancy_signal do
        :none -> false
        :active -> process_mode === :active
        :passive -> process_mode === :passive
        :all -> true
      end
    end
  end
end
