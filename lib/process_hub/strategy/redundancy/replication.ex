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

  > #### State Handover Incompatibility {: .warning}
  >
  > State handover (`:handover` option in `ColdSwap` or `HotSwap` migration strategies) is
  > **not supported** with the Replication strategy. With replication, multiple instances
  > of a process run across the cluster, making state handover semantics undefined.
  > Attempting to use `handover: true` with replication will cause the hub to fail at startup.
  """

  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Utility.Extractor
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

    @impl true
    def handle_redundancy(strategy, hub, registry_data, nodes) do
      # Handle replication redundancy when nodes join.
      # This includes:
      # 1. Starting replicas locally if this node should now have a replica
      # 2. Stopping replicas locally if this node should no longer have a replica
      # 3. Sending mode signals for active/passive transitions

      Replication.do_handle_redundancy(strategy, hub, registry_data, nodes)
    end
  end

  @spec handle_post_start(struct(), Hub.t(), [
          {ProcessHub.child_id(), pid(), [node()]}
        ]) :: :ok
  def handle_post_start(%__MODULE__{redundancy_signal: :none}, _, _), do: :ok

  def handle_post_start(strategy, hub, post_start_data) do
    # Fetch canonical node list from distribution strategy to ensure consistent mode calculation
    dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())
    repl_fact = RedundancyStrategy.replication_factor(strategy)
    local_node = node()

    # OPTIMIZATION: Batch belongs_to() call for all children upfront instead of
    # calling it individually inside the loop. This reduces 10k hash ring lookups to 1.
    all_child_ids = Enum.map(post_start_data, &elem(&1, 0))

    canonical_nodes_map =
      DistributionStrategy.belongs_to(dist_strat, hub, all_child_ids, repl_fact)

    Enum.each(post_start_data, fn {child_id, res, child_pid, _child_nodes} ->
      # Only process if:
      # 1. child_pid is a local pid
      # 2. The process was actually newly started (result is :ok), not already_started
      # This prevents sending incorrect signals during redistribution when a migration
      # event is received for a process that already exists locally
      is_new_start = res === :ok or (is_tuple(res) and elem(res, 0) === :ok)

      if is_new_start and is_pid(child_pid) and node(child_pid) === local_node do
        # Get canonical nodes from pre-computed map (O(1) lookup)
        canonical_nodes = Map.get(canonical_nodes_map, child_id, [])

        mode = process_mode(strategy, hub, child_id, canonical_nodes)

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
    # Process both UP and DOWN events
    # For UP events: use curr_master_on_stable (excludes joining node) for mode decisions
    # For DOWN events: use curr_master_new (remaining nodes)
    Enum.each(processes_data, fn {child_id, nodes, nodes_old, opts} ->
      handle_redundancy_signal(
        strategy,
        hub,
        child_id,
        {nodes, nodes_old},
        {node_action, node},
        opts
      )
    end)
  end

  def handle_post_update(_, _, _), do: :ok

  defp node_modes(strategy, hub, child_id, nodes, node_action) do
    {new_nodes, old_nodes} = nodes

    # Calculate prev_master on old_nodes (the distribution before the event)
    prev_master = RedundancyStrategy.master_node(strategy, hub, child_id, old_nodes)

    # Calculate curr_master on new_nodes (the planned distribution after the event)
    curr_master_on_new = RedundancyStrategy.master_node(strategy, hub, child_id, new_nodes)

    # For UP events, also calculate master on stable nodes (intersection)
    # This is used for conservative "becoming active" decisions
    curr_master_on_stable =
      case node_action do
        :up ->
          stable_nodes = Enum.filter(new_nodes, fn n -> Enum.member?(old_nodes, n) end)

          if Enum.empty?(stable_nodes) do
            # Fall back to old master if no stable nodes
            prev_master
          else
            RedundancyStrategy.master_node(strategy, hub, child_id, stable_nodes)
          end

        :down ->
          curr_master_on_new
      end

    # Return both: on_new for handoff decisions, on_stable for becoming active
    {prev_master, curr_master_on_new, curr_master_on_stable}
  end

  # Handle redundancy signals for both UP and DOWN events
  # For UP events: Special handling based on whether joining node will be master
  # For DOWN events: use curr_master_on_new (remaining nodes)
  defp handle_redundancy_signal(
         strategy,
         hub,
         child_id,
         nodes,
         {node_action, joining_or_leaving_node},
         opts
       ) do
    local_node = node()
    {new_nodes, old_nodes_from_registry} = nodes

    # Use old_nodes from registry - it should be correct as it comes from group_children
    # which reads from the local registry's node_pids for this child
    old_nodes = old_nodes_from_registry

    {prev_master, curr_master_new, _curr_master_stable} =
      node_modes(strategy, hub, child_id, {new_nodes, old_nodes}, node_action)

    # Only process if local_node was running the process before (in old_nodes)
    if Enum.member?(old_nodes, local_node) do
      case node_action do
        :up ->
          # For UP events: Check if the JOINING node will be the new master
          # If so, only send :passive to the old master (if local)
          # The joining node will get its :active mode from handle_post_start
          # If joining node is NOT the new master, we can safely use curr_master_new
          joining_node_is_new_master = curr_master_new === joining_or_leaving_node

          cond do
            joining_node_is_new_master and prev_master === local_node ->
              # I was master, joining node will be master - I become passive
              if Enum.member?([:all, :passive], strategy.redundancy_signal) do
                child_pid(hub, child_id, opts) |> send_redundancy_signal(:passive)
              end

            joining_node_is_new_master ->
              # Joining node will be master, but I wasn't master before - no change
              :ok

            prev_master === curr_master_new ->
              # Master didn't change - no mode change needed
              :ok

            prev_master === local_node and curr_master_new !== local_node ->
              # I was master, now an existing node is master - I become passive
              if Enum.member?([:all, :passive], strategy.redundancy_signal) do
                child_pid(hub, child_id, opts) |> send_redundancy_signal(:passive)
              end

            curr_master_new === local_node and prev_master !== local_node ->
              # I become master (not the joining node) - I become active
              if Enum.member?([:all, :active], strategy.redundancy_signal) do
                child_pid(hub, child_id, opts) |> send_redundancy_signal(:active)
              end

            true ->
              :ok
          end

        :down ->
          # For DOWN events: always send the correct signal based on curr_master.
          # This ensures modes are synchronized even if previous signals were
          # processed out of order or with stale ring data across different nodes.
          cond do
            curr_master_new === local_node ->
              # I am the master based on current ring state - ensure I'm active
              if Enum.member?([:all, :active], strategy.redundancy_signal) do
                child_pid(hub, child_id, opts) |> send_redundancy_signal(:active)
              end

            true ->
              # I am not the master - ensure I'm passive
              if Enum.member?([:all, :passive], strategy.redundancy_signal) do
                child_pid(hub, child_id, opts) |> send_redundancy_signal(:passive)
              end
          end
      end
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
    case Keyword.get(opts, :pid) do
      nil ->
        ProcessRegistry.local_pid(hub.hub_id, child_id)

      # Handle case where pid is a registry entry tuple {child_spec, node_pids, metadata}
      {_child_spec, node_pids, _metadata} when is_list(node_pids) ->
        Keyword.get(node_pids, node())

      pid when is_pid(pid) ->
        pid

      _other ->
        nil
    end
  end

  defp send_redundancy_signal(pid, mode) when is_pid(pid) do
    # Only send if the process is alive and local
    if Process.alive?(pid) do
      send(pid, {:process_hub, :redundancy_signal, mode})
    end
  end

  defp send_redundancy_signal(_pid, _mode), do: nil

  @doc false
  def do_handle_redundancy(strategy, hub, registry_data, nodes) do
    local_node = node()
    dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())
    repl_fact = RedundancyStrategy.replication_factor(strategy)

    # Calculate new distribution for all children
    cids = Enum.map(registry_data, fn {cid, _} -> cid end)

    cid_node_pairs =
      if length(cids) > 0 do
        DistributionStrategy.belongs_to(dist_strat, hub, cids, repl_fact)
      else
        %{}
      end

    # Get currently running local children
    local_pids =
      hub.hub_id
      |> ProcessRegistry.local_children()
      |> Extractor.local_cid_pid_pairs()

    local_child_ids = Map.keys(local_pids)

    # Process each child for redundancy updates
    Enum.each(registry_data, fn {child_id, {_cs, node_pids, _m}} ->
      _nodes_old = Keyword.keys(node_pids)

      nodes_new = Map.get(cid_node_pairs, child_id, [])

      running_locally = Enum.member?(local_child_ids, child_id)
      should_be_local = Enum.member?(nodes_new, local_node)

      # Only send mode signals for processes that are running locally and staying local
      if running_locally and should_be_local do
        # Check if any of the joining nodes affects this child's distribution
        relevant_to_new_nodes = Enum.any?(nodes, fn n -> Enum.member?(nodes_new, n) end)

        if relevant_to_new_nodes do
          # Send mode signal based on current master calculation
          local_pid = Map.get(local_pids, child_id)

          if is_pid(local_pid) do
            mode = process_mode(strategy, hub, child_id, nodes_new)

            cond do
              strategy.redundancy_signal === :all ->
                send_redundancy_signal(local_pid, mode)

              mode === strategy.redundancy_signal ->
                send_redundancy_signal(local_pid, mode)

              true ->
                :ok
            end
          end
        end
      end
    end)

    :ok
  end
end
