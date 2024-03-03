defmodule ProcessHub.Strategy.Migration.HotSwap do
  @moduledoc """
  The hot swap migration strategy implements the `ProcessHub.Strategy.Migration.Base` protocol.
  It provides a migration strategy where the local process is terminated after the new one is
  started on the remote node.

  In the following text, we will refer to the process that is being terminated after the migration
  as the peer process.

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
  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.Mailbox
  alias ProcessHub.Utility.Name

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
  """
  @type t() :: %__MODULE__{
          retention: pos_integer(),
          handover: boolean()
        }
  defstruct retention: 5000, handover: false

  defimpl MigrationStrategy, for: ProcessHub.Strategy.Migration.HotSwap do
    alias ProcessHub.Service.ProcessRegistry
    @migration_timeout 15000

    @impl true
    def init(_strategy, _hub_id), do: nil

    @impl true
    def handle_migration(strategy, hub_id, child_specs, added_node, sync_strategy) do
      # Start redistribution of the child processes.
      Distributor.children_redist_init(hub_id, child_specs, added_node, reply_to: [self()])

      if length(child_specs) > 0 do
        migration_cids = migration_cids(hub_id, strategy, child_specs, added_node)

        handle_retentions(hub_id, strategy, sync_strategy, migration_cids)

        if length(migration_cids) > 0 do
          # Dispatch hook.
          HookManager.dispatch_hook(hub_id, Hook.children_migrated(), {added_node, child_specs})
        end
      end

      :ok
    end

    @impl true
    def handle_shutdown(_strategy, hub_id) do
      # Get all the child specs that belong to the local node.
      ProcessRegistry.local_children(hub_id)

      # Get all states of the local children.

      # Find out the nodes where the children are being migrated.

      # Send the state to the remote nodes.
    end

    defp handle_retentions(hub_id, strategy, sync_strategy, migration_cids) do
      Enum.reduce(migration_cids, :continue, fn
        child_id, :continue ->
          # Wait for response from the peer process and then terminate the child from local node.
          retention_signal = handle_retention(strategy, child_id)
          Distributor.child_terminate(hub_id, child_id, sync_strategy)
          retention_signal

        child_id, :kill ->
          # Terminate the local child immediately.
          Distributor.child_terminate(hub_id, child_id, sync_strategy)
          :kill
      end)

      # Distributor.children_terminate(hub_id, migration_cids, sync_strategy)
    end

    defp migration_cids(hub_id, strategy, child_specs, added_node) do
      dist_sup = Name.distributed_supervisor(hub_id)

      local_pids = DistributedSupervisor.local_children(dist_sup)

      Enum.map(1..length(child_specs), fn _x ->
        start_resp =
          Mailbox.receive_response(
            :child_start_resp,
            receive_handler(),
            @migration_timeout
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

      defp send_handover_start(pid, cid, from, state) do
        Process.send(pid, {:process_hub, :handover, state}, [])
        Process.send(from, {:process_hub, :retention_handled, cid}, [])
      end
    end
  end
end
