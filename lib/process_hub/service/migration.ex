defmodule ProcessHub.Service.Migration do
  @moduledoc """
  Basic, oracle-coordinated hub-to-hub process migration.

  `migrate_process/4` moves a process from a source hub to a target hub, handing
  the previous process's state to the new one via the `ProcessHub.Migration.Handover`
  contract (no transparent capture).

  The migration is delegated to the leader-hosted oracle
  (`ProcessHub.Service.Oracle.coordinate/2`), which serializes it per
  `{child_id, source, target}` and de-duplicates redundant/concurrent requests
  (the "migration token"). The oracle, as the single owner, drives the sequence:

      snapshot (export) → stop on source → start on target → deliver → commit

  If the target start fails after the source was stopped, the oracle rolls back
  by restarting the process on the source hub with the snapshot, so the process
  is never lost (it ends up in exactly one hub).

  This basic migration moves a **single-instance** (e.g. `Singularity`) process; a
  replicated child (more than one live location) returns
  `{:error, :replicated_not_supported}` rather than collapsing its replicas.

  > #### State handover {: .info}
  >
  > State is carried over only if the process supports `ProcessHub.Migration.Handover`
  > (`use` the macro, or implement the handler messages). Otherwise it migrates
  > **without** its state.
  """

  alias ProcessHub.Service.Oracle
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Future
  alias ProcessHub.StartResult

  # How long to wait for the source's handover state before migrating without it.
  @handover_timeout_ms 5_000

  @type result() ::
          {:ok, map()}
          | {:rolled_back, term()}
          | {:error, :no_oracle | :source_not_found | :replicated_not_supported | term()}

  @doc """
  Migrates `child_id` from `source_hub` to `target_hub` with state handoff.

  Returns `{:ok, info}` on success, `{:rolled_back, reason}` if the target start
  failed and the process was restored on the source, or `{:error, reason}`.

  ## Options
    * `:target_spec` — child spec to start on the target hub (defaults to the
      source's spec). Useful when the target needs different start arguments.
  """
  @spec migrate_process(ProcessHub.hub_id(), ProcessHub.hub_id(), ProcessHub.child_id(), keyword()) ::
          result()
  def migrate_process(source_hub, target_hub, child_id, opts \\ []) do
    token = {:migration, child_id, source_hub, target_hub}

    case Oracle.coordinate(token, {__MODULE__, :run, [source_hub, target_hub, child_id, opts]}) do
      {:ok, result} -> result
      {:already_done, result} -> result
      {:error, :no_oracle} = error -> error
    end
  end

  @doc false
  # Runs on the oracle node, inside the oracle's serialized coordination.
  @spec run(ProcessHub.hub_id(), ProcessHub.hub_id(), ProcessHub.child_id(), keyword()) :: result()
  def run(source_hub, target_hub, child_id, opts) do
    case ProcessRegistry.lookup(source_hub, child_id) do
      nil ->
        {:error, :source_not_found}

      {_source_spec, node_pids} when length(node_pids) > 1 ->
        # Basic migration moves a single-instance process; a replicated child
        # would need replication-factor-aware placement on the target, so fail
        # loud rather than silently collapse its replicas.
        {:error, :replicated_not_supported}

      {source_spec, [{_node, source_pid}]} ->
        target_spec = Keyword.get(opts, :target_spec, source_spec)
        do_migrate(source_hub, target_hub, child_id, source_spec, source_pid, target_spec)
    end
  end

  ##############################################################################
  ### Private functions
  ##############################################################################

  defp do_migrate(source_hub, target_hub, child_id, source_spec, source_pid, target_spec) do
    # Snapshot the source's handover state (if it supports the contract), then
    # stop it and start on the target. Message-based handover means nothing here
    # blocks indefinitely or risks crashing the oracle.
    handover = export_state(source_pid, child_id)
    stop_child(source_hub, child_id)

    case start_child(target_hub, target_spec) do
      {:ok, target_pid} ->
        deliver_state(target_pid, child_id, handover)

        {:ok,
         %{
           child_id: child_id,
           from: source_hub,
           to: target_hub,
           node: node(target_pid),
           pid: target_pid
         }}

      {:error, reason} ->
        # rollback: restore the process on the source with the snapshot.
        rollback(source_hub, source_spec, child_id, handover)
        {:rolled_back, reason}
    end
  end

  # Ask the source for its handover state via the `ProcessHub.Migration.Handover`
  # contract. Returns `{:ok, state}` if it replies, `:no_handover` otherwise.
  defp export_state(source_pid, child_id) do
    send(source_pid, {:process_hub, :query_migration_handover_state, self(), child_id})

    receive do
      {:process_hub, :migration_state, ^child_id, state} -> {:ok, state}
    after
      @handover_timeout_ms -> :no_handover
    end
  end

  defp deliver_state(_pid, _child_id, :no_handover), do: :ok

  defp deliver_state(pid, child_id, {:ok, state}) do
    send(pid, {:process_hub, :migration_handover, child_id, state})
    :ok
  end

  defp rollback(source_hub, source_spec, child_id, handover) do
    case start_child(source_hub, source_spec) do
      {:ok, pid} -> deliver_state(pid, child_id, handover)
      {:error, _reason} -> :error
    end
  end

  defp stop_child(hub_id, child_id) do
    # Awaitable stop blocks (via the request manager's reply — message passing,
    # not polling) until the stop has actually completed.
    case hub_id |> ProcessHub.stop_child(child_id, awaitable: true) |> Future.await() do
      # Op completed before we awaited; it is already done.
      {:error, :pending_request_not_found} -> :ok
      _result -> :ok
    end
  end

  defp start_child(hub_id, spec) do
    case hub_id |> ProcessHub.start_child(spec, awaitable: true) |> Future.await() do
      %StartResult{status: :ok} = result ->
        {:ok, StartResult.pid(result)}

      %StartResult{} = result ->
        {:error, StartResult.errors(result)}

      # Cross-node race: the operation completed before we awaited, so read the
      # pid from the registry (the source of truth) directly.
      {:error, :pending_request_not_found} ->
        case ProcessRegistry.lookup(hub_id, spec.id) do
          {_spec, [{_node, pid} | _]} -> {:ok, pid}
          _ -> {:error, :start_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
