defmodule ProcessHub.Service.DeclaredChildren.Boot do
  @moduledoc """
  Boot-time resolution of the declared list: adopts the highest version among
  the local store and the remote manifest, seeds version 1 from durable
  registry rows on first enablement, and parks the hub's reconcile when the
  list is missing while durable evidence says it should exist.
  """

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.DeclaredChildren
  alias ProcessHub.Service.DeclaredChildren.Store
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.LoggerService
  alias ProcessHub.Service.Storage
  alias ProcessHub.Storage.RemoteManifest
  alias ProcessHub.Hub

  @remote_timeout 5_000

  @doc """
  Resolves the list on coordinator boot. A stored format newer than this
  release refuses to open.
  """
  @spec run(Hub.t()) :: {:ok, :ready | :parked | {:remote_error, term()}} | {:error, term()}
  def run(hub) do
    case Store.read(hub) do
      {:error, _} = error -> error
      {:ok, local} -> resolve(hub, local, remote_fetch(hub))
    end
  end

  defp resolve(hub, local, remote) do
    case {local, remote} do
      {%{} = local, {:ok, %{} = remote_manifest}} ->
        settle_versions(hub, local, remote_manifest)

      {%{} = local, remote} when remote in [:not_configured, :not_found] ->
        Store.cache(hub, local)
        if remote === :not_found, do: Store.ship(hub, local)
        {:ok, :ready}

      {%{} = local, {:error, reason}} ->
        Store.cache(hub, local)
        warn_remote_unreachable(hub, reason)
        {:ok, {:remote_error, reason}}

      {nil, {:ok, %{} = remote_manifest}} ->
        DeclaredChildren.adopt(hub, remote_manifest)

        LoggerService.notice(
          "Declared list restored from the remote manifest at v@version",
          %{"version" => Integer.to_string(remote_manifest.version)},
          prefix: "DeclaredChildren",
          hub_id: hub.hub_id
        )

        {:ok, :ready}

      {nil, remote} when remote in [:not_configured, :not_found] ->
        if Store.seeded?(hub), do: park(hub, :local_list_lost), else: seed(hub)

      {nil, {:error, reason}} ->
        if Store.seeded?(hub) or durable_evidence?(hub) do
          park(hub, {:remote_unreachable, reason})
        else
          warn_remote_unreachable(hub, reason)
          seed(hub)
        end
    end
  end

  defp settle_versions(hub, local, remote_manifest) do
    cond do
      remote_manifest.version > local.version ->
        DeclaredChildren.adopt(hub, remote_manifest)

      remote_manifest.version < local.version ->
        Store.cache(hub, local)
        Store.ship(hub, local)

      true ->
        Store.cache(hub, local)
    end

    {:ok, :ready}
  end

  # First enablement: version 1 from the durable registry rows, minus rows the
  # superseded lifecycle model had marked stopped (their files may predate this
  # release). Runs once — the seeded marker survives list-file rotation.
  defp seed(hub) do
    entries =
      case Storage.read_durable(hub.hub_id) do
        {:ok, rows} ->
          Enum.reduce(rows, %{}, fn
            {child_id, {%{} = child_spec, node_pids, metadata}}, acc
            when is_list(node_pids) and is_map(metadata) ->
              case metadata do
                %{__process_hub__: %{lifecycle: :stopped}} -> acc
                _ -> Map.put(acc, child_id, child_spec)
              end

            _row, acc ->
              acc
          end)

        {:error, _} ->
          %{}
      end

    version = if map_size(entries) === 0, do: 0, else: 1
    manifest = DeclaredChildren.new_manifest(version, entries)

    case Store.write(hub, manifest) do
      :ok ->
        if version > 0, do: Store.ship(hub, manifest)

        LoggerService.notice(
          "Declared list seeded at v@version with @count children",
          %{
            "version" => Integer.to_string(version),
            "count" => Integer.to_string(map_size(entries))
          },
          prefix: "DeclaredChildren",
          hub_id: hub.hub_id
        )

        {:ok, :ready}

      {:error, reason} ->
        {:error, {:declared_list_write_failed, reason}}
    end
  end

  defp durable_evidence?(hub) do
    case Storage.read_durable(hub.hub_id) do
      {:ok, rows} -> rows !== []
      # An unreadable durable medium cannot rule evidence out; refuse to assume
      # emptiness.
      {:error, _} -> true
    end
  end

  defp park(hub, reason) do
    Store.set_parked(hub)

    LoggerService.error(
      "Declared list is missing or corrupt while durable evidence exists (@reason). " <>
        "The reconcile is parked: no child is started or stopped for this hub. " <>
        "Restore the list file or a remote manifest copy, or clear it explicitly with " <>
        "ProcessHub.Service.DeclaredChildren.clear/1.",
      %{"reason" => inspect(reason)},
      prefix: "DeclaredChildren",
      hub_id: hub.hub_id
    )

    HookManager.dispatch_hook(hub.storage.hook, Hook.declared_parked(), %{
      hub_id: hub.hub_id,
      reason: reason
    })

    {:ok, :parked}
  end

  defp warn_remote_unreachable(hub, reason) do
    LoggerService.warning(
      "Remote manifest unreachable on boot (@reason); falling back to the local list",
      %{"reason" => inspect(reason)},
      prefix: "DeclaredChildren",
      hub_id: hub.hub_id
    )
  end

  @doc """
  Re-runs the boot-time remote comparison after a remote outage at boot. MUST
  run inside the coordinator process.
  """
  @spec remote_recompare(Hub.t()) :: :ok | {:error, term()}
  def remote_recompare(hub) do
    case remote_fetch(hub) do
      {:ok, %{} = remote_manifest} ->
        DeclaredChildren.adopt(hub, remote_manifest)
        Store.clear_parked(hub)
        :ok

      :not_found ->
        with %{} = local <- DeclaredChildren.manifest(hub), do: Store.ship(hub, local)
        :ok

      :not_configured ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc "Fetches and decodes the remote copy, bounded and off the caller's heap."
  @spec remote_fetch(Hub.t()) ::
          {:ok, DeclaredChildren.manifest()} | :not_found | :not_configured | {:error, term()}
  def remote_fetch(%Hub{recovery_config: %{remote_manifest: nil}}), do: :not_configured

  def remote_fetch(hub) do
    {module, opts} = hub.recovery_config.remote_manifest

    task =
      Task.Supervisor.async_nolink(hub.procs.task_sup, fn ->
        module.fetch(hub.hub_id, opts)
      end)

    case Task.yield(task, @remote_timeout) || Task.shutdown(task) do
      {:ok, {:ok, {_version, blob}}} -> decode_supported(blob)
      {:ok, :not_found} -> :not_found
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, reason} -> {:error, {:adapter_crashed, reason}}
      nil -> {:error, :remote_fetch_timeout}
    end
  end

  defp decode_supported(blob) do
    with {:ok, %{format: format} = manifest} <- RemoteManifest.decode(blob) do
      if format > DeclaredChildren.format(),
        do: {:error, :unsupported_remote_format},
        else: {:ok, manifest}
    end
  end
end
