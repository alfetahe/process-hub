defmodule ProcessHub.Strategy.Migration.HotSwap do
  @moduledoc """
  The hot swap migration strategy implements the `ProcessHub.Strategy.Migration.Base` protocol.
  It provides a migration strategy where the local process is terminated after the new one is
  started on the remote node.

  In the following text, we will refer to the process that is being terminated after the migration
  as the peer process.

  Hotswap migration can also handle process state migration when nodes are leaving the cluster.
  The process states are stored in the local storage and are sent to the remote node before the
  local process is terminated. This will only work if the node is being shut down **gracefully**.

  The hot swap strategy is useful when we want to ensure that there is no downtime when migrating
  the child process to the remote node. It also provides a way to ensure that the state of the
  process is synchronized before terminating the peer process.

  To pass the process state to the newly started process on the remote node, the
  `:handover` option must be set to `true` in the migration strategy configuration, and
  necessary messages must be handled in the processes.

  > #### Using the handover option {: .warning}
  >
  > When the `:handover` option is set to `true`, the peer process must handle the following message:
  > `{:process_hub, :handover_start, startup_resp, from}`.

  Example migration with handover using `GenServer`:

  ```elixir
  def handle_info({:process_hub, :handover_start, startup_resp, child_id, from}, state) do
    case startup_resp do
      {:ok, pid} ->
        # Send the state to the remote process.
        Process.send(pid, {:process_hub, :handover, state}, [])

        # Signal the handler process that the state handover has been handled.
        Process.send(from, {:process_hub, :retention_handled, child_id}, [])

      _ ->
        nil
    end

    {:noreply, state}
  end

  def handle_info({:process_hub, :handover, handover_state}, _state) do
    {:noreply, handover_state}
  end
  ```

  > #### Use HotSwap macro to provide the handover callbacks automatically.  {: .info}
  > It's convenient to use the `HotSwap` macro to provide the handover callbacks automatically.
  >
  > ```elixir
  > use ProcessHub.Strategy.Migration.HotSwap
  > ```
  """

  require Logger

  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.Mailbox
  alias ProcessHub.Utility.Name
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Strategy.Migration.HotSwap

  @typedoc """
  Hot-swap migration strategy configuration.
  Available options:
  - `:retention` - An integer value in milliseconds is used to specify how long
    the peer process should be kept alive after a new child process has been started on the remote node.
    This option is used to ensure that the peer process has had enough time to perform any cleanup
    or state synchronization before the local process is terminated.
    Keep in mind that process will be terminated before the retention time has passed if the peer process
    has notified the handler process that the state transfer has been handled.
    The default value is `5000`.

  - `:handover` - A boolean value. If set to `true`, the processes involved in the migration
    must handle the following message: `{:process_hub, :handover_start, startup_resp, from}`.
    This message will be sent to the peer process that will be terminated after the migration.
    The variable `startup_resp` will contain the response from the `ProcessHub.DistributedSupervisor.start_child/2` function, and if
    successful, it will be `{:ok, pid}`. The PID can be used to send the state of the process to the
    remote process.
    If the `retention` option is used, then the peer process has to signal the handler process
    that the state has been handled; otherwise, the handler will wait until the default retention time has passed.
    The handler PID is passed in the `from` variable.
    The default value is `false`.

  - `:handover_data_wait` - An integer value in milliseconds is used to specify how long the handler process
    should wait for the state of the remote process to be sent to the local node.
    The default value is `3000`.

  - `:child_migration_timeout` - An integer value in milliseconds is used to specify the timeout for single
  child process migration. If the child process migration does not complete within this time, the migration
  for single child process will be considered failed but the migration for other child processes will continue.
    The default value is `10000`.
  """
  @type t() :: %__MODULE__{
          retention: pos_integer(),
          handover: boolean(),
          handover_data_wait: pos_integer(),
          child_migration_timeout: pos_integer()
        }
  defstruct retention: 5000,
            handover: false,
            handover_data_wait: 3000,
            child_migration_timeout: 10000

  defimpl MigrationStrategy, for: ProcessHub.Strategy.Migration.HotSwap do
    @impl true
    def init(struct, hub_id) do
      shutdown_handler = %HookManager{
        id: :mhs_shutdown,
        m: ProcessHub.Strategy.Migration.HotSwap,
        f: :handle_shutdown,
        a: [struct, hub_id]
      }

      process_startups_handler = %HookManager{
        id: :mhs_process_startups,
        m: ProcessHub.Strategy.Migration.HotSwap,
        f: :handle_process_startups,
        a: [struct, hub_id, :_]
      }

      HookManager.register_handler(hub_id, Hook.process_startups(), process_startups_handler)
      HookManager.register_handler(hub_id, Hook.coordinator_shutdown(), shutdown_handler)
    end

    @impl true
    def handle_migration(struct, hub_id, child_specs, added_node, sync_strategy) do
      Distributor.children_redist_init(hub_id, added_node, child_specs, reply_to: [self()])

      if length(child_specs) > 0 do
        migration_cids = migration_cids(hub_id, struct, child_specs, added_node)

        handle_retentions(hub_id, struct, sync_strategy, migration_cids)

        if length(migration_cids) > 0 do
          HookManager.dispatch_hook(hub_id, Hook.children_migrated(), {added_node, child_specs})
        end
      end

      :ok
    end

    defp handle_retentions(hub_id, strategy, sync_strategy, migration_cids) do
      Enum.reduce(migration_cids, :continue, fn
        child_id, :continue ->
          # Wait for response from the peer process.
          handle_retention(strategy, child_id)

        _child_id, :kill ->
          :kill
      end)

      Distributor.children_terminate(hub_id, migration_cids, sync_strategy)
    end

    defp migration_cids(hub_id, %HotSwap{} = strategy, child_specs, added_node) do
      dist_sup = Name.distributed_supervisor(hub_id)

      local_pids = DistributedSupervisor.local_children(dist_sup)

      Enum.map(1..length(child_specs), fn _x ->
        start_resp =
          Mailbox.receive_response(
            :child_start_resp,
            receive_handler(),
            strategy.child_migration_timeout
          )

        case start_resp do
          {:error, _reason} ->
            Logger.error("Migration failed to start on node #{inspect(added_node)}")
            nil

          {child_id, result} ->
            # Notify the peer process about the migration.
            case start_handover(strategy, child_id, local_pids, result) do
              nil -> nil
              _ -> child_id
            end
        end
      end)
      |> Enum.filter(&(&1 != nil))
      |> retention_switch(strategy)
    end

    defp retention_switch(child_ids, strategy) do
      Process.send_after(self(), {:process_hub, :retention_over}, strategy.retention)

      child_ids
    end

    defp receive_handler() do
      fn _child_id, resp, _node ->
        resp
      end
    end

    defp start_handover(strategy, child_id, local_pids, result) do
      case strategy.handover do
        true ->
          pid = Map.get(local_pids, child_id)

          if is_pid(pid) do
            send(pid, {:process_hub, :handover_start, result, child_id, self()})
          end

        false ->
          nil
      end
    end

    defp handle_retention(strategy, child_id) do
      receive do
        {:process_hub, :retention_over} ->
          :kill

        {:process_hub, :retention_handled, ^child_id} ->
          :continue
      after
        strategy.retention ->
          :kill
      end
    end
  end

  def handle_shutdown(%__MODULE__{handover: true, handover_data_wait: hodw} = _struct, hub_id) do
    ProcessRegistry.local_data(hub_id)
    |> get_state_msgs()
    |> get_send_data(hodw)
    |> format_send_data(hub_id)
    |> send_data(hub_id)

    :ok
  end

  def handle_shutdown(_struct, _hub_id), do: :ok

  def handle_process_startups(%__MODULE__{handover: true} = _struct, hub_id, cpids) do
    state_data = Storage.get(Name.local_storage(hub_id), StorageKey.msk()) || []

    Enum.each(cpids, fn %{cid: cid, pid: pid} ->
      pstate = Keyword.get(state_data, cid, nil)

      unless pstate === nil do
        send(pid, {:process_hub, :handover, pstate})
      end
    end)

    rem_states(hub_id, Keyword.keys(state_data))
  end

  def handle_process_startups(_struct, _hub_id, _pids), do: nil

  defp rem_states(hub_id, cids) do
    Name.local_storage(hub_id)
    |> Storage.update(StorageKey.msk(), fn
      nil -> nil
      states -> Enum.reject(states, fn {cid, _} -> Enum.member?(cids, cid) end)
    end)
  end

  defp send_data(send_data, hub_id) do
    # Send the data to each node now.
    Enum.each(send_data, fn {node, data} ->
      cluster_nodes = Cluster.nodes(hub_id)

      if Enum.member?(cluster_nodes, node) do
        # Need to be sure that this is sent and handled on the remote nodes
        # before they start the new children.
        :erpc.call(node, fn ->
          Storage.update(Name.local_storage(hub_id), StorageKey.msk(), fn old_value ->
            case old_value do
              nil -> data
              _ -> data ++ old_value
            end
          end)
        end)
      end
    end)
  end

  defp format_send_data({local_data, states}, hub_id) do
    local_storage = Name.local_storage(hub_id)
    dist_strat = Storage.get(local_storage, StorageKey.strdist())

    repl_fact =
      Storage.get(local_storage, StorageKey.strred())
      |> RedundancyStrategy.replication_factor()

    Enum.reduce(local_data, %{}, fn {cid, {_, cn}}, acc ->
      nodes = Keyword.keys(cn)
      new_nodes = DistributionStrategy.belongs_to(dist_strat, hub_id, cid, repl_fact)
      migration_node = Enum.find(new_nodes, fn node -> not Enum.member?(nodes, node) end)
      node_data = Map.get(acc, migration_node, [])

      Map.put(acc, migration_node, [{cid, Keyword.get(states, cid)} | node_data])
    end)
  end

  defp get_state_msgs(local_data) do
    local_node = node()
    self = self()

    Enum.each(local_data, fn {child_id, {_cs, cn}} ->
      local_pid = Keyword.get(cn, local_node)

      if is_pid(local_pid) do
        send(local_pid, {:process_hub, :get_state, child_id, self})
      end
    end)

    local_data
  end

  defp get_send_data(local_data, handover_data_wait) do
    local_node = node()

    send_data =
      Enum.map(local_data, fn _x ->
        receive do
          {:process_hub, :process_state, cid, state} ->
            {cid, state}
        after
          handover_data_wait ->
            Logger.error("Handover timeout while shutting down the node #{local_node}")
            nil
        end
      end)
      |> Enum.filter(&(&1 != nil))

    {local_data, send_data}
  end

  defmacro __using__(_) do
    quote do
      require Logger

      def handle_info({:process_hub, :handover_start, startup_resp, cid, from}, state) do
        case startup_resp do
          {:error, {:already_started, pid}} ->
            send_handover_start(pid, cid, from, state)

          {:ok, pid} ->
            send_handover_start(pid, cid, from, state)

          error ->
            Logger.error("Handover failed: #{inspect(error)}")
        end

        {:noreply, state}
      end

      def handle_info({:process_hub, :handover, handover_state}, _state) do
        {:noreply, handover_state}
      end

      def handle_info({:process_hub, :get_state, cid, from}, state) do
        send(from, {:process_hub, :process_state, cid, state})

        {:noreply, state}
      end

      defp send_handover_start(pid, cid, from, state) do
        Process.send(pid, {:process_hub, :handover, state}, [])
        Process.send(from, {:process_hub, :retention_handled, cid}, [])
      end
    end
  end
end
