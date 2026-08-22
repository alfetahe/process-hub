defmodule ProcessHub.Service.DeclaredChildren.Store do
  @moduledoc """
  Local persistence of the declared list: the DETS-backed store beside the
  registry file, the misc-storage read cache, the seeded marker, the park flag,
  and the hand-off to the remote-manifest shipper. Every stored manifest goes
  through `write/2`, so the persist-before-cache order and the seeded marker
  are maintained in one place.
  """

  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.DeclaredChildren
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.Storage.DetsFile
  alias ProcessHub.Service.Storage.DurableEts
  alias ProcessHub.Hub

  @doc """
  Opens the list's durable store; returns the `:declared_backend` and
  `:declared_path` entries for the hub's storage map. Called by the initializer
  when the feature gate is on.
  """
  @spec open(ProcessHub.hub_id(), term()) :: %{
          declared_backend: {module(), term()},
          declared_path: String.t()
        }
  def open(hub_id, registry_backend) do
    path = list_path(hub_id, registry_backend)
    {:ok, ref} = DurableEts.open(:"#{hub_id}_declared_list", path: path)

    %{declared_backend: {DurableEts, ref}, declared_path: path}
  end

  # Sibling of the exact registry file (not just its directory), so nodes that
  # share a filesystem but use per-node registry paths get per-node list files.
  defp list_path(hub_id, registry_backend) do
    registry_opts =
      case registry_backend do
        {kind, opts} when kind in [:dets, :durable_ets] and is_list(opts) -> opts
        _ -> []
      end

    base = DetsFile.resolve_path(hub_id, registry_opts)
    Path.rootname(base) <> ".declared.dets"
  end

  @doc "Persists `manifest`, refreshes the read cache, and sets the seeded marker."
  @spec write(Hub.t(), DeclaredChildren.manifest(), keyword()) :: :ok | {:error, term()}
  def write(hub, manifest, write_opts \\ []) do
    {module, ref} = hub.storage.declared_backend

    case module.insert_many(ref, [{:manifest, manifest, []}], write_opts) do
      :ok ->
        cache(hub, manifest)
        mark_seeded(hub)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc "Makes every manifest written with `sync: false` durable."
  @spec sync(Hub.t()) :: :ok | {:error, term()}
  def sync(hub) do
    {module, ref} = hub.storage.declared_backend
    module.sync(ref)
  end

  @doc "Refreshes the misc-storage read cache for an already-persisted manifest."
  @spec cache(Hub.t(), DeclaredChildren.manifest()) :: :ok | boolean()
  def cache(hub, manifest) do
    Storage.insert(hub.storage.misc, StorageKey.dcl(), manifest)
  end

  @doc """
  Reads the persisted manifest: `{:ok, manifest | nil}` (missing and malformed
  both read as absent), or an error for a format newer than this release.
  """
  @spec read(Hub.t()) :: {:ok, DeclaredChildren.manifest() | nil} | {:error, term()}
  def read(hub) do
    {module, ref} = hub.storage.declared_backend
    supported = DeclaredChildren.format()

    case module.get(ref, :manifest) do
      %{format: format} when format > supported ->
        {:error, {:declared_list_format_unsupported, format}}

      %{format: _, version: _, mutated_by: _, entries: %{}} = manifest ->
        {:ok, manifest}

      _missing_or_malformed ->
        {:ok, nil}
    end
  end

  # The marker is a separate file beside the list so it survives the list
  # file's corruption rotation — it is what distinguishes "list lost" from
  # "never enabled".
  @doc "Returns whether the hub has ever stored a list (marker survives rotation)."
  @spec seeded?(Hub.t()) :: boolean()
  def seeded?(hub) do
    case Map.get(hub.storage, :declared_path) do
      nil -> false
      path -> File.exists?(path <> ".seeded")
    end
  end

  defp mark_seeded(hub) do
    with path when is_binary(path) <- Map.get(hub.storage, :declared_path),
         marker = path <> ".seeded",
         false <- File.exists?(marker) do
      File.write(marker, "1")
    end

    :ok
  end

  @doc "Sets the park flag the reconcile and mutations check."
  @spec set_parked(Hub.t()) :: :ok | boolean()
  def set_parked(hub), do: Storage.insert(hub.storage.misc, StorageKey.dclp(), true)

  @doc "Lifts the park flag."
  @spec clear_parked(Hub.t()) :: :ok | boolean()
  def clear_parked(hub), do: Storage.remove(hub.storage.misc, StorageKey.dclp())

  @doc "Hands the manifest to the remote shipper; a no-op without a remote."
  @spec ship(Hub.t(), DeclaredChildren.manifest()) :: :ok
  def ship(%Hub{recovery_config: %{remote_manifest: nil}}, _manifest), do: :ok

  def ship(hub, manifest) do
    GenServer.cast(hub.procs.manifest_shipper, {:ship, manifest})
    :ok
  catch
    _, _ -> :ok
  end
end
