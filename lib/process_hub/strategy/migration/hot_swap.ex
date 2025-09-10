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

  > #### Use HotSwap macro to provide the handover callbacks automatically.  {: .info}
  > If the `:handover` option is set to `true`, the process must implement the necessary callbacks.
  > This can be done by using the `ProcessHub.Strategy.Migration.HotSwap` macro.
  >
  > ```elixir
  > use ProcessHub.Strategy.Migration.HotSwap
  > ```
  >
  > Additionally, the user can override the `alter_handover_state/1` function to modify the state
  > before it is set as the new state for the child process. The function must return the modified state.
  > ```elixir
  > defmodule MyProcess do
  >   use ProcessHub.Strategy.Migration.HotSwap
  >
  >   def alter_handover_state(state) do
  >     # Modify the state here
  >     state
  >   end
  > end
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
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Strategy.Migration.HotSwap
  alias ProcessHub.StartResult

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
    must handle the following message: `{:process_hub, :send_handover_state, receiver_pid, child_id, opts}`.
    This message will be sent to the peer process that will be terminated after the migration.
    The variable `receiver_pid` is the PID of the process who is expecting to receive the message
    containing the state of the peer process.
    If the `:retention` option is used, then the peer process has to signal the handler process
    that the state has been handled; otherwise, the handler will wait until the default retention time has passed.
    The handler PID is passed in the `from` variable. The `retention_receiver` pid can be accessed from the `opts` variable.
    The default value is `false`.

  - `:confirm_handover` - A boolean value indicating if the state handover process should be performed synchronously.
  This option only takes effect if `:handover` is turned on. Default value is `false`.

  - `:handover_data_wait` - An integer value in milliseconds is used to specify how long the handler process
    should wait for the state of the remote process to be sent to the local node.
    The default value is `3000`.

  - `:child_migration_timeout` - An integer value in milliseconds is used to specify the timeout for single
  child process migration. If the child process migration does not complete within this time, the migration
  for this child process will be considered failed but the migration for other child processes will continue.
    The default value is `10000`.
  """
  @type t() :: %__MODULE__{
          retention: pos_integer(),
          handover: boolean(),
          confirm_handover: boolean(),
          handover_data_wait: pos_integer(),
          child_migration_timeout: pos_integer()
        }
  defstruct retention: 5000,
            handover: false,
            confirm_handover: false,
            handover_data_wait: 3000,
            child_migration_timeout: 10000

  defimpl MigrationStrategy, for: ProcessHub.Strategy.Migration.HotSwap do
    @impl true
    def init(struct, hub) do
      shutdown_handler = %HookManager{
        id: :mhs_shutdown,
        m: ProcessHub.Strategy.Migration.HotSwap,
        f: :handle_shutdown,
        a: [struct, hub],
        p: 100
      }

      process_startups_handler = %HookManager{
        id: :mhs_process_startups,
        m: ProcessHub.Strategy.Migration.HotSwap,
        f: :handle_process_startups,
        a: [struct, hub, :_],
        p: 100
      }

      HookManager.register_handler(
        hub.storage.hook,
        Hook.coordinator_shutdown(),
        shutdown_handler
      )

      HookManager.register_handler(
        hub.storage.hook,
        Hook.process_startups(),
        process_startups_handler
      )

      struct
    end

    @impl true
    def handle_migration(struct, hub, children_data, added_node, sync_strategy) do
      Distributor.children_redist_init(hub, added_node, children_data, reply_to: [self()])

      if length(children_data) > 0 do
        child_specs = Enum.map(children_data, fn {cspec, _m} -> cspec end)
        migration_cids = migration_cids(hub, struct, child_specs, added_node)

        handle_retentions(hub, struct, sync_strategy, migration_cids)

        if length(migration_cids) > 0 do
          HookManager.dispatch_hook(
            hub.storage.hook,
            Hook.children_migrated(),
            {added_node, children_data}
          )
        end
      end

      :ok
    end

    defp handle_retentions(hub, strategy, sync_strategy, migration_cids) do
      Enum.reduce(migration_cids, :continue, fn
        child_id, :continue ->
          # Wait for response from the peer process.
          handle_retention(strategy, child_id)

        _child_id, :kill ->
          :kill
      end)

      Distributor.children_terminate(hub, migration_cids, sync_strategy)

      # Wait for handover confirmation messages.
      if strategy.confirm_handover do
        Enum.each(migration_cids, fn cid -> confirm_handover(strategy, cid) end)
      end
    end

    defp migration_cids(hub, %HotSwap{} = strategy, child_specs, added_node) do
      local_pids = DistributedSupervisor.local_children(hub.procs.dist_sup)

      handler = fn _cid, _node, result ->
        case result do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, err} -> {:error, err}
        end
      end

      opts = [
        timeout: strategy.child_migration_timeout,
        collect_from: [added_node],
        result_handler: handler,
        required_cids: Enum.map(child_specs, fn %{id: cid} -> cid end)
      ]

      success_results =
        case Mailbox.collect_start_results(hub, opts) |> StartResult.format() do
          {:ok, results} ->
            results

          {:error, {errors, sresults}} ->
            Enum.each(errors, fn {error, node} ->
              Logger.error("Child process migration failed on node #{node}: #{inspect(error)}")
            end)

            sresults
        end

      Enum.map(success_results, fn {child_id, child_results} ->
        # Because we are migrating we only expect one node result.
        started_pid = List.first(child_results) |> elem(1)

        handle_started(hub, strategy, child_id, local_pids, started_pid)
      end)
      |> Enum.filter(&(&1 != nil))
      |> retention_switch(strategy)
    end

    defp handle_started(hub, strategy, child_id, local_pids, started_pid) do
      # Notify the peer process about the migration.
      case start_handover(hub, strategy, child_id, local_pids, started_pid) do
        nil -> nil
        _ -> child_id
      end
    end

    defp retention_switch(child_ids, strategy) do
      Process.send_after(self(), {:process_hub, :retention_over}, strategy.retention)

      child_ids
    end

    defp start_handover(hub, strategy, child_id, local_pids, handover_receiver) do
      case strategy.handover do
        true ->
          pid = Map.get(local_pids, child_id)
          confirmation_receiver = if strategy.confirm_handover, do: handover_receiver, else: nil

          if is_pid(pid) do
            send(pid, {
              :process_hub,
              :send_handover_state,
              handover_receiver,
              child_id,
              [
                retention_receiver: self(),
                confirmation_receiver: confirmation_receiver,
                confirm_handover: strategy.confirm_handover,
                hub_id: hub.hub_id
              ]
            })
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

    def confirm_handover(strategy, child_id) do
      receive do
        {:process_hub, :handover_confirmed, ^child_id} ->
          :ok
      after
        strategy.retention ->
          {:error, "handover confirmation timeout"}
      end
    end
  end

  def handle_shutdown(%__MODULE__{handover: true, handover_data_wait: hodw} = _struct, hub) do
    # Make sure there are other nodes in the cluster left.
    if Cluster.nodes(hub.storage.misc) |> length() > 0 do
      ProcessRegistry.local_data(hub.hub_id)
      |> get_state_msgs()
      |> get_send_data(hodw)
      |> format_send_data(hub)
      |> send_data(hub)
    end

    :ok
  end

  def handle_shutdown(_struct, _hub_id), do: :ok

  def handle_process_startups(%__MODULE__{handover: true} = _struct, hub, cpids) do
    state_data = Storage.get(hub.storage.misc, StorageKey.msk()) || []

    Enum.each(cpids, fn %{cid: cid, pid: pid} ->
      pstate = Enum.find(state_data, fn {child_id, _} -> child_id === cid end)

      if is_tuple(pstate) do
        send(pid, {:process_hub, :handover, cid, pstate |> elem(1)})
      end
    end)

    rem_states(Enum.map(state_data, fn {cid, _} -> cid end), hub.storage.misc)
  end

  def handle_process_startups(_struct, _hub_id, _pids), do: nil

  def handle_storage_update(hub, data) do
    Storage.update(hub.storage.misc, StorageKey.msk(), fn old_value ->
      case old_value do
        nil -> data
        _ -> data ++ old_value
      end
    end)
  end

  defp rem_states(cids, misc_storage) do
    Storage.update(misc_storage, StorageKey.msk(), fn
      nil -> nil
      states -> Enum.reject(states, fn {cid, _} -> Enum.member?(cids, cid) end)
    end)
  end

  defp send_data(send_data, hub) do
    # Send the data to each node now.
    Enum.each(send_data, fn {node, data} ->
      cluster_nodes = Cluster.nodes(hub.storage.misc)

      if Enum.member?(cluster_nodes, node) && Enum.member?(Node.list(), node) do
        GenServer.cast(
          {hub.hub_id, node},
          {:exec_cast, {__MODULE__, :handle_storage_update, [data]}}
        )
      end
    end)
  end

  defp format_send_data({local_data, states}, hub) do
    dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())

    repl_fact =
      Storage.get(hub.storage.misc, StorageKey.strred())
      |> RedundancyStrategy.replication_factor()

    cids = Enum.map(local_data, & &1.cid)

    Enum.reduce(cids, %{}, fn {cid, new_nodes}, acc ->
      case Map.get(local_data, cid) do
        nil ->
          acc

        {_, cn, _m} ->
          nodes = Keyword.keys(cn)
          migration_node = Enum.find(new_nodes, fn node -> not Enum.member?(nodes, node) end)
          node_data = Map.get(acc, migration_node, [])

          case migration_node do
            nil ->
              acc

            _ ->
              migr_data =
                (Enum.find(
                   states,
                   fn {child_id, _} -> child_id === cid end
                 ) || {nil, nil})
                |> elem(1)

              Map.put(acc, migration_node, [{cid, migr_data} | node_data])
          end
      end
    end)
  end

  defp get_state_msgs(local_data) do
    local_node = node()
    self = self()

    Enum.each(local_data, fn {child_id, {_cs, cn, _m}} ->
      local_pid = Keyword.get(cn, local_node)

      if is_pid(local_pid) do
        send(local_pid, {:process_hub, :send_handover_state, self, child_id, []})
      end
    end)

    local_data
  end

  defp get_send_data(local_data, handover_data_wait) do
    local_node = node()

    send_data =
      Enum.map(local_data, fn _x ->
        receive do
          {:process_hub, :handover, cid, state} ->
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
      @behaviour ProcessHub.Strategy.Migration.HotSwapBehaviour

      @impl true
      def handle_info({:process_hub, :send_handover_state, receiver, cid, opts}, state) do
        if is_pid(receiver) do
          prepared_state = prepare_handover_state(state)
          Process.send(receiver, {:process_hub, :handover, cid, {prepared_state, opts}}, [])
        end

        if is_pid(opts[:retention_receiver]) do
          Process.send(opts[:retention_receiver], {:process_hub, :retention_handled, cid}, [])
        end

        {:noreply, state}
      end

      @impl true
      def handle_info({:process_hub, :handover, cid, {handover_state, opts}}, state) do
        case Keyword.get(opts, :confirm_handover, false) do
          true ->
            Process.send(
              opts[:confirmation_receiver],
              {:process_hub, :handover_confirmed, cid},
              []
            )

          false ->
            nil
        end

        {:noreply, alter_handover_state(state, handover_state)}
      end

      @impl true
      def prepare_handover_state(state), do: state

      @impl true
      def alter_handover_state(_current_state, handover_state), do: handover_state

      defoverridable prepare_handover_state: 1, alter_handover_state: 2
    end
  end
end

defmodule ProcessHub.Strategy.Migration.HotSwapBehaviour do
  @moduledoc """
  This module defines the behaviour for the hot swap migration strategy.
  It provides the necessary callbacks that must be implemented by the processes
  that use this strategy.
  """

  @callback prepare_handover_state(state :: term()) :: term()
  @callback alter_handover_state(current_state :: term(), handover_state :: term()) :: term()
end
