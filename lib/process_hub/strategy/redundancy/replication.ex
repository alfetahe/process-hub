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

  > Replication strategy selects the master/active node based on the `child_id` and
  > `child_nodes` arguments. The `child_id` is converted to a charlist and summed up.
  > The sum is then used to calculate the index of the master node in the `child_nodes` list.
  > This ensures that the same master node is selected for the same `child_id` and `child_nodes`
  > arguments.

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
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Hub

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
    alias ProcessHub.Service.HookManager
    alias ProcessHub.Strategy.Redundancy.Replication

    @impl true
    def init(strategy, hub) do
      HookManager.register_handler(hub.storage.hook, Hook.post_children_start(), %HookManager{
        id: :rr_post_start,
        m: Replication,
        f: :handle_post_start,
        a: [strategy, hub, :_],
        p: 100
      })

      HookManager.register_handler(
        hub.storage.hook,
        Hook.pre_children_redistribution(),
        %HookManager{
          id: :rr_post_update,
          m: Replication,
          f: :handle_post_update,
          a: [strategy, hub, :_],
          p: 100
        }
      )

      strategy
    end

    @impl true
    @spec replication_factor(Replication.t()) ::
            pos_integer() | :cluster_size
    def replication_factor(strategy) do
      case strategy.replication_factor do
        :cluster_size ->
          (Node.list() |> Enum.count()) + 1

        _ ->
          strategy.replication_factor
      end
    end

    @impl true
    @spec master_node(struct(), Hub.t(), ProcessHub.child_id(), [node()]) :: node()
    def master_node(_strategy, _hub, child_id, child_nodes) do
      child_nodes = Enum.sort(child_nodes)

      child_total =
        cond do
          is_binary(child_id) -> child_id
          is_atom(child_id) -> Atom.to_string(child_id)
        end
        |> to_charlist()
        |> Enum.sum()

      nodes_total = length(child_nodes)
      index = rem(child_total, nodes_total)

      Enum.at(child_nodes, index)
    end
  end

  @spec handle_post_start(struct(), Hub.t(), [
          {ProcessHub.child_id(), pid(), [node()]}
        ]) :: :ok
  def handle_post_start(%__MODULE__{redundancy_signal: :none}, _, _), do: :ok

  def handle_post_start(strategy, hub, post_start_data) do
    Enum.each(post_start_data, fn {child_id, res, child_pid, child_nodes} ->
      mode = process_mode(strategy, hub, child_id, child_nodes)

      if elem(res, 0) === :ok do
        cond do
          strategy.redundancy_signal === :all ->
            send_redundancy_signal(child_pid, mode)

          mode === strategy.redundancy_signal ->
            send_redundancy_signal(child_pid, mode)

          true ->
            :ok
        end
      end
    end)

    :ok
  end

  @spec handle_post_update(
          struct(),
          Hub.t(),
          {[{ProcessHub.child_id(), [node()], keyword()}], {:up | :down, node()}}
        ) :: :ok
  def handle_post_update(%__MODULE__{redundancy_signal: :none}, _, _), do: :ok

  def handle_post_update(
        %__MODULE__{replication_model: :active_passive} = strategy,
        hub,
        {processes_data, {node_action, node}}
      ) do


    dbg({"POST UPDATE", node(), node_action, node, processes_data})

    Enum.each(processes_data, fn {child_id, child_nodes, opts} ->
      handle_redundancy_signal(
        strategy,
        hub,
        child_id,
        child_nodes,
        {node_action, node},
        opts
      )
    end)
  end

  def handle_post_update(_, _, _), do: :ok

  defp node_modes(strategy, hub, node_action, child_id, nodes, node) do
    curr_master = RedundancyStrategy.master_node(strategy, hub, child_id, nodes)

    prev_master =
      case node_action do
        :up ->
          # Remove the new node from the list to calculate the previous master
          prev_nodes = Enum.filter(nodes, fn n -> n !== node end)
          RedundancyStrategy.master_node(strategy, hub, child_id, prev_nodes)

        :down ->
          # Add the removed node back to calculate the previous master
          prev_nodes = Enum.sort([node | nodes])
          RedundancyStrategy.master_node(strategy, hub, child_id, prev_nodes)
      end

      dbg({"NODE MODES", node(), child_id, prev_master, curr_master, nodes, node_action})

    {prev_master, curr_master}
  end

  defp handle_redundancy_signal(strategy, hub, child_id, nodes, {node_action, node}, opts) do
    local_node = node()

    {prev_master, curr_master} =
      node_modes(strategy, hub, node_action, child_id, nodes, node)

    cond do
      prev_master === curr_master ->
        # Do nothing because the same node still holds the active process.
        :ok

      # Node transitioned from passive to active
      curr_master === local_node and prev_master !== local_node ->
        if Enum.member?([:all, :active], strategy.redundancy_signal) do
          # Current node is the new active node.
          child_pid(hub, child_id, opts) |> send_redundancy_signal(:active)
        end

      # Node transitioned from active to passive
      prev_master === local_node and curr_master !== local_node ->
        if Enum.member?([:all, :passive], strategy.redundancy_signal) do
          dbg({"SEND PASSIVE", node(), child_id})

          # Current node is the new passive node.
          child_pid(hub, child_id, opts)|> dbg() |> send_redundancy_signal(:passive)
        end

      true ->
        :ok
    end
  end

  defp process_mode(%__MODULE__{replication_model: rp} = strat, hub, child_id, child_nodes) do
    master_node = RedundancyStrategy.master_node(strat, hub, child_id, child_nodes)

    cond do
      rp === :active_active ->
        :active

      master_node === node() ->
        :active

      true ->
        :passive
    end
  end

  defp child_pid(hub, child_id, opts) do
    dbg()

    case Keyword.get(opts, :pid) do
      nil ->
        DistributedSupervisor.local_pid(hub.procs.dist_sup, child_id)

      pid ->
        pid
    end
  end

  defp send_redundancy_signal(pid, mode) when is_pid(pid) do
    send(pid, {:process_hub, :redundancy_signal, mode})
  end

  defp send_redundancy_signal(_pid, _mode), do: nil
end
