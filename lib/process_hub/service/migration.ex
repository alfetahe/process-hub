defmodule ProcessHub.Service.Migration do
  @moduledoc """
  Basic, oracle-coordinated hub-to-hub process migration.

  `migrate_process/4` moves a process from a source hub to a target hub, handing
  the previous process's state to the new one via the explicit
  `ProcessHub.Migration.Handover` contract (no transparent capture).

  The migration is delegated to the leader-hosted oracle
  (`ProcessHub.Service.Oracle.coordinate/2`), which serializes it per
  `{child_id, source, target}` and de-duplicates redundant/concurrent requests
  (the "migration token"). The oracle, as the single owner, drives the sequence:

      freeze (suspend source) → snapshot (export) → stop on source →
      start on target → import → commit

  If the target start fails after the source was stopped, the oracle rolls back
  by restarting the process on the source hub with the snapshot, so the process
  is never lost (it ends up in exactly one hub).
  """

  alias ProcessHub.Service.Oracle
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Future
  alias ProcessHub.StartResult

  # Bound on confirming a start/stop has taken effect (and synced to this node).
  @op_timeout_ms 8_000

  @type result() ::
          {:ok, map()}
          | {:rolled_back, term()}
          | {:error, :no_oracle | :source_not_found | term()}

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

      {source_spec, node_pids} ->
        source_pid = node_pids |> List.first() |> elem(1)
        module = spec_module(source_spec)
        target_spec = Keyword.get(opts, :target_spec, source_spec)
        do_migrate(source_hub, target_hub, child_id, source_spec, source_pid, target_spec, module)
    end
  end

  ##############################################################################
  ### Private functions
  ##############################################################################

  defp do_migrate(source_hub, target_hub, child_id, source_spec, source_pid, target_spec, module) do
    # freeze: stop the source from processing so no updates are lost between the
    # snapshot and the stop.
    freeze(source_pid)
    export = export_state(module, source_pid)

    # stop on source (removes it from the source registry and terminates the pid).
    stop_child(source_hub, child_id)

    # start on target; the target node is chosen by the target hub's strategy.
    case start_child(target_hub, target_spec) do
      {:ok, target_pid} ->
        import_state(module, target_pid, export)

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
        rollback(source_hub, source_spec, module, export)
        {:rolled_back, reason}
    end
  end

  defp freeze(pid) do
    try do
      :sys.suspend(pid)
    catch
      _kind, _reason -> :ok
    end
  end

  defp export_state(module, pid) do
    raw = :sys.get_state(pid)

    if function_exported?(module, :handover_export, 1) do
      module.handover_export(raw)
    else
      raw
    end
  end

  defp import_state(module, pid, export) do
    if function_exported?(module, :handover_import, 2) do
      :sys.replace_state(pid, fn state -> module.handover_import(export, state) end)
    else
      :sys.replace_state(pid, fn _state -> export end)
    end

    :ok
  end

  defp stop_child(hub_id, child_id) do
    ProcessHub.stop_child(hub_id, child_id)
    # Confirm removal (and its sync to this node) before proceeding.
    await_unregistered(hub_id, child_id, @op_timeout_ms)
  end

  defp start_child(hub_id, spec) do
    case hub_id |> ProcessHub.start_child(spec, awaitable: true) |> Future.await() do
      %StartResult{status: :ok} = result ->
        {:ok, StartResult.pid(result)}

      %StartResult{} = result ->
        {:error, StartResult.errors(result)}

      # Cross-node race: the operation completed before we awaited. Fall back to
      # the registry (the source of truth), allowing for a brief sync window.
      {:error, :pending_request_not_found} ->
        await_registered(hub_id, spec.id, @op_timeout_ms)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_registered(hub_id, child_id, timeout) do
    poll_until(timeout, fn ->
      case ProcessRegistry.lookup(hub_id, child_id) do
        {_spec, [{_node, pid} | _]} -> {:ok, pid}
        _ -> :retry
      end
    end) || {:error, :start_failed}
  end

  defp await_unregistered(hub_id, child_id, timeout) do
    poll_until(timeout, fn ->
      if ProcessRegistry.lookup(hub_id, child_id) == nil, do: :ok, else: :retry
    end) || :ok
  end

  defp poll_until(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_until(deadline, fun)
  end

  defp do_poll_until(deadline, fun) do
    case fun.() do
      :retry ->
        if System.monotonic_time(:millisecond) > deadline do
          nil
        else
          Process.sleep(50)
          do_poll_until(deadline, fun)
        end

      result ->
        result
    end
  end

  defp rollback(source_hub, source_spec, module, export) do
    case start_child(source_hub, source_spec) do
      {:ok, pid} -> import_state(module, pid, export)
      {:error, _reason} -> :error
    end
  end

  defp spec_module(%{start: {module, _fun, _args}}), do: module
  defp spec_module(_spec), do: nil
end
