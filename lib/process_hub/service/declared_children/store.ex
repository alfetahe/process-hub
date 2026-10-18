defmodule ProcessHub.Service.DeclaredChildren.Store do
  @moduledoc """
  Local persistence of the declared list: the DETS-backed store beside the
  registry file, one row per declared child plus a version row, the seeded
  marker, the park flag, and the hand-off to the remote-manifest shipper.
  Every write goes through `persist/4`, so the seeded marker is maintained in
  one place, and reads come from the store's in-memory side.
  """

  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.DeclaredChildren
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.Storage.DetsFile
  alias ProcessHub.Service.Storage.DurableEts
  alias ProcessHub.Service.Storage.Ets
  alias ProcessHub.Hub

  @meta :meta
  @entry :declared
  @tombstone :removed
  @legacy :manifest

  @typedoc "The manifest without its entries: what the version row holds."
  @type meta() :: %{format: pos_integer(), version: non_neg_integer(), mutated_by: node()}

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

  @doc """
  Persists `manifest` in full: the version row, and only the entries that
  differ from the stored ones. Removed children are dropped.
  """
  @spec write(Hub.t(), DeclaredChildren.manifest()) :: :ok | {:error, term()}
  def write(hub, %{entries: entries} = manifest) do
    stored = entries(hub)
    puts = Enum.reject(entries, fn {id, spec} -> Map.get(stored, id) === spec end)
    removes = for id <- Map.keys(stored), not Map.has_key?(entries, id), do: id

    persist(hub, Map.delete(manifest, :entries), puts, removes)
  end

  @doc """
  Persists a batch: `puts` (`[{child_id, spec}]`) and `removes` (child ids)
  under the version row `meta`, in one synced write.

  Each child is its own row, so a batch costs its own size rather than the
  whole list's. A removal is written as a tombstone in that same write, so
  the version and every change of the batch land together, and the tombstone
  row is dropped after the sync.
  """
  @spec persist(Hub.t(), meta(), [{ProcessHub.child_id(), ProcessHub.child_spec()}], [
          ProcessHub.child_id()
        ]) :: :ok | {:error, term()}
  def persist(hub, meta, puts, removes) do
    backend = hub.storage.declared_backend

    items =
      [{@meta, meta, []} | for({id, spec} <- puts, do: {{@entry, id}, spec, []})] ++
        for id <- removes, do: {{@entry, id}, @tombstone, []}

    with :ok <- Storage.insert_many(backend, items) do
      drop(backend, removes)
      mark_seeded(hub)
      :ok
    end
  end

  @doc "The stored version row, or `nil` when no list was ever stored."
  @spec meta(Hub.t()) :: meta() | nil
  def meta(hub) do
    case get(hub, @meta) do
      %{format: _, version: _, mutated_by: _} = meta -> meta
      _ -> nil
    end
  end

  @doc "The stored spec of `child_id`, or `nil` when it is not declared."
  @spec entry(Hub.t(), ProcessHub.child_id()) :: ProcessHub.child_spec() | nil
  def entry(hub, child_id) do
    case get(hub, {@entry, child_id}) do
      @tombstone -> nil
      spec -> spec
    end
  end

  @doc "Every stored entry, as `%{child_id => spec}`."
  @spec entries(Hub.t()) :: %{ProcessHub.child_id() => ProcessHub.child_spec()}
  def entries(%Hub{storage: %{declared_backend: backend}}) do
    Storage.foldl_entries(backend, %{}, fn
      {{@entry, _id}, @tombstone}, acc -> acc
      {{@entry, id}, spec}, acc -> Map.put(acc, id, spec)
      _other, acc -> acc
    end)
  end

  def entries(_hub_without_list), do: %{}

  # A hub with the gate off has no list store, and reads as declaring nothing.
  defp get(%Hub{storage: %{declared_backend: backend}}, key), do: Storage.get(backend, key)
  defp get(_hub_without_list, _key), do: nil

  @doc """
  Reads the persisted manifest: `{:ok, manifest | nil}` (missing and malformed
  both read as absent), or an error for a format newer than this release.
  A list stored whole by an earlier release is rewritten one row per child.
  """
  @spec read(Hub.t()) :: {:ok, DeclaredChildren.manifest() | nil} | {:error, term()}
  def read(hub) do
    backend = hub.storage.declared_backend
    supported = DeclaredChildren.format()

    # The legacy row outlives the version row only when a migration was cut
    # short; either one in a newer format refuses the open.
    case {Storage.get(backend, @meta), Storage.get(backend, @legacy)} do
      {%{format: format}, _legacy} when format > supported ->
        {:error, {:declared_list_format_unsupported, format}}

      {_meta, %{format: format}} when format > supported ->
        {:error, {:declared_list_format_unsupported, format}}

      {%{format: _, version: _, mutated_by: _} = meta, _legacy} ->
        Storage.remove(backend, @legacy, sync: false)
        drop(backend, tombstones(backend))
        {:ok, Map.put(meta, :entries, entries(hub))}

      {nil, %{format: _, version: _, mutated_by: _, entries: %{}} = legacy} ->
        migrate(hub, legacy)

      _missing_or_malformed ->
        {:ok, nil}
    end
  end

  defp migrate(hub, manifest) do
    case write(hub, manifest) do
      :ok ->
        Storage.remove(hub.storage.declared_backend, @legacy)
        {:ok, manifest}

      {:error, reason} ->
        {:error, {:declared_list_write_failed, reason}}
    end
  end

  # A crash between a batch's sync and its tombstone drop leaves the rows behind.
  defp tombstones(backend) do
    Storage.foldl_entries(backend, [], fn
      {{@entry, id}, @tombstone}, acc -> [id | acc]
      _other, acc -> acc
    end)
  end

  defp drop(backend, ids) do
    for id <- ids, do: Storage.remove(backend, {@entry, id}, sync: false)
    :ok
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

  @doc """
  Tells the remote shipper the list reached `version`; it reads the list
  itself when it ships. A no-op without a remote.
  """
  @spec ship(Hub.t(), non_neg_integer()) :: :ok
  def ship(%Hub{recovery_config: %{remote_manifest: nil}}, _version), do: :ok

  def ship(hub, version) do
    GenServer.cast(hub.procs.manifest_shipper, {:ship, version})
    :ok
  catch
    _, _ -> :ok
  end
end
