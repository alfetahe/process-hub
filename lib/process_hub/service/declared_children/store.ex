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
  alias ProcessHub.Service.Storage.Ets
  alias ProcessHub.Hub

  @doc """
  Opens the list's store; returns the `:declared_backend` entry for the hub's
  storage map, and `:declared_path` when the list is kept on disk. Called by the
  initializer when the feature gate is on.

  The list is only as durable as the registry: a hub whose registry keeps
  nothing on disk gets an in-memory list too.
  """
  @spec open(ProcessHub.hub_id(), term()) :: %{
          required(:declared_backend) => {module(), term()},
          optional(:declared_path) => String.t()
        }
  def open(hub_id, registry_backend) do
    case list_path(registry_backend) do
      nil ->
        {:ok, ref} = Ets.open(:"#{hub_id}_declared_list", [])
        %{declared_backend: {Ets, ref}}

      path ->
        {:ok, ref} = DurableEts.open(:"#{hub_id}_declared_list", path: path)
        %{declared_backend: {DurableEts, ref}, declared_path: path}
    end
  end

  # Sibling of the exact registry file (not just its directory), so nodes that
  # share a filesystem but use per-node registry paths get per-node list files.
  # A backend that named no file has no sibling to sit beside, and a hub that
  # keeps nothing on disk should not have a list forced onto it: nil keeps the
  # list in memory. Any backend carrying a :path gets a durable list, custom
  # ones included.
  defp list_path({_kind, opts}) when is_list(opts) do
    case DetsFile.configured_path(opts) do
      nil -> nil
      path -> Path.rootname(path) <> ".declared.dets"
    end
  end

  defp list_path(_registry_backend), do: nil

  @doc "Persists `manifest`, refreshes the read cache, and sets the seeded marker."
  @spec write(Hub.t(), DeclaredChildren.manifest()) :: :ok | {:error, term()}
  def write(hub, manifest) do
    {module, ref} = hub.storage.declared_backend

    case module.insert(ref, :manifest, manifest) do
      :ok ->
        cache(hub, manifest)
        mark_seeded(hub)
        :ok

      {:error, _} = error ->
        error
    end
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
