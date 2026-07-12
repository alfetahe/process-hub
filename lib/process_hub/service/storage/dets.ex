defmodule ProcessHub.Service.Storage.Dets do
  @moduledoc """
  DETS-backed registry storage. Selected via
  `registry_backend: {:dets, opts}` on `ProcessHub.t()`.

  ### Durability

  Every successful mutation (`insert/3`, `insert/4`, `remove/2`,
  `clear_all/1`) calls `:dets.sync/1` before returning, so any operation
  observed as `:ok` by the caller is durable on disk.

  ### File location

  By default the file is stored at
  `priv/process_hub/<hub_id>/registry.dets` resolved against the
  application's `priv` directory. Override with the `:path` option:

      registry_backend: {:dets, path: "/var/lib/myapp/hub.dets"}

  The parent directory is created if it does not exist.

  ### Recovery on corruption

  On open the file is passed `repair: true`. If `:dets.open_file/2`
  still returns `{:error, _}`, the corrupt file is rotated to
  `<path>.corrupt-<system_monotonic>`, telemetry
  `[:process_hub, :registry, :backend_corrupt]` is emitted, and a fresh
  empty file is opened at the original path.

  ### TTL

  DETS has no native TTL. Entries inserted with `:ttl` are stored as
  `{key, value, expire_ms}` (matching the ETS layout). Reads filter
  expired entries on the way out. A periodic sweeper is out of scope —
  expired entries accumulate until manually swept.
  """

  @behaviour ProcessHub.Service.Storage.Behaviour

  alias ProcessHub.Service.Storage.DetsFile
  alias ProcessHub.Service.Storage.Entry

  @impl true
  @spec open(atom(), keyword()) :: {:ok, atom()} | {:error, term()}
  def open(hub_id, opts) when is_atom(hub_id) do
    path = DetsFile.resolve_path(hub_id, opts)
    replay? = Keyword.get(opts, :recovery_replay, true)
    File.mkdir_p!(Path.dirname(path))

    {result, _repaired?} =
      case :dets.open_file(hub_id, file: to_charlist(path), repair: true, type: :set) do
        {:ok, table} ->
          {{:ok, table}, false}

        {:error, reason} ->
          DetsFile.rotate_and_reopen(hub_id, path, reason)
      end

    case result do
      {:ok, table} ->
        unless replay? do
          :dets.delete_all_objects(table)
          :dets.sync(table)
        end

        {:ok, table}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  @spec close(atom()) :: :ok
  def close(ref) do
    case :dets.close(ref) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  @impl true
  @spec insert(atom(), term(), term()) :: :ok | {:error, term()}
  def insert(ref, key, value) do
    do_insert(ref, {key, value})
  end

  @impl true
  @spec insert(atom(), term(), term(), keyword()) :: :ok | {:error, term()}
  def insert(ref, key, value, opts) do
    do_insert(ref, Entry.build(key, value, opts))
  end

  @impl true
  @spec insert_many(atom(), [{term(), term(), keyword()}]) :: :ok | {:error, term()}
  def insert_many(ref, items) do
    do_insert(ref, Entry.build_many(items))
  end

  @impl true
  @spec get(atom(), term()) :: term() | nil
  def get(ref, key) do
    case :dets.lookup(ref, key) do
      [] -> nil
      [entry | _] -> Entry.value(entry)
    end
  end

  @impl true
  @spec exists?(atom(), term()) :: boolean()
  def exists?(ref, key) do
    case :dets.lookup(ref, key) do
      [] -> false
      [entry | _] -> not Entry.expired?(entry)
    end
  end

  @impl true
  @spec remove(atom(), term()) :: :ok | {:error, term()}
  def remove(ref, key) do
    case :dets.delete(ref, key) do
      :ok ->
        :dets.sync(ref)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec export_all(atom()) :: list()
  def export_all(ref) do
    :dets.foldl(
      fn entry, acc ->
        if Entry.expired?(entry), do: acc, else: [entry | acc]
      end,
      [],
      ref
    )
  end

  @impl true
  @spec foldl(atom(), term(), (term(), term() -> term())) :: term()
  def foldl(ref, acc, fun) do
    :dets.foldl(
      fn entry, acc_in ->
        if Entry.expired?(entry), do: acc_in, else: fun.(entry, acc_in)
      end,
      acc,
      ref
    )
  end

  @impl true
  @spec match(atom(), term()) :: list()
  def match(ref, match_expr) do
    case :dets.match(ref, match_expr) do
      {:error, _} -> []
      matches when is_list(matches) -> Enum.map(matches, &List.to_tuple/1)
    end
  end

  @impl true
  @spec clear_all(atom()) :: :ok | {:error, term()}
  def clear_all(ref) do
    case :dets.delete_all_objects(ref) do
      :ok ->
        :dets.sync(ref)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Helpers ----------------------------------------------------------------

  # `:dets.insert/2` takes a single object or a list; either way one sync
  # makes the whole write durable.
  defp do_insert(ref, objects) do
    case :dets.insert(ref, objects) do
      :ok ->
        :dets.sync(ref)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
