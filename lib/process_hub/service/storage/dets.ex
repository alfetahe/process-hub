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
  `<path>.corrupt-<system_monotonic>`, an error is logged, and a fresh
  empty file is opened at the original path.

  ### TTL

  DETS has no native TTL. Entries inserted with `:ttl` are stored as
  `{key, value, expire_ms}` (matching the ETS layout). Reads filter
  expired entries on the way out. Expired rows are swept by
  `ProcessHub.Worker.Janitor`.

  ### Non-replaying open

  The DETS file is both the durable medium and the live view for this
  backend, so `recovery_replay: false` cannot be implemented by dropping
  rows — that would destroy the very state a returning node needs. Instead
  the keys present at open are recorded in a small in-memory *shadow set*
  and filtered out of every read; they stay on disk and remain readable
  through `read_durable/1`. Writing or removing a key un-shadows it, so a
  row restored by the orphan reconcile becomes visible again.
  """

  @behaviour ProcessHub.Service.Storage.Behaviour

  alias ProcessHub.Service.Storage.DetsFile
  alias ProcessHub.Service.Storage.Entry

  @typedoc "DETS table name paired with the shadow set of keys hidden from reads."
  @type ref() :: {atom(), :ets.tid()}

  @impl true
  @spec open(atom(), keyword()) :: {:ok, ref()} | {:error, term()}
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
        shadow = :ets.new(:dets_registry_shadow, [:set, :public, read_concurrency: true])
        unless replay?, do: shadow_existing_keys(table, shadow)
        {:ok, {table, shadow}}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  @spec close(ref()) :: :ok
  def close({table, shadow}) do
    case :ets.info(shadow) do
      :undefined -> :ok
      _ -> :ets.delete(shadow)
    end

    case :dets.close(table) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  @impl true
  @spec insert(ref(), term(), term()) :: :ok | {:error, term()}
  def insert(ref, key, value) do
    do_insert(ref, {key, value})
  end

  @impl true
  @spec insert(ref(), term(), term(), keyword()) :: :ok | {:error, term()}
  def insert(ref, key, value, opts) do
    do_insert(ref, Entry.build(key, value, opts))
  end

  @impl true
  @spec insert_many(ref(), [{term(), term(), keyword()}]) :: :ok | {:error, term()}
  def insert_many(ref, items) do
    do_insert(ref, Entry.build_many(items))
  end

  @impl true
  @spec get(ref(), term()) :: term() | nil
  def get({table, shadow}, key) do
    case visible_lookup(table, shadow, key) do
      nil -> nil
      entry -> Entry.value(entry)
    end
  end

  @impl true
  @spec exists?(ref(), term()) :: boolean()
  def exists?({table, shadow}, key) do
    case visible_lookup(table, shadow, key) do
      nil -> false
      entry -> not Entry.expired?(entry)
    end
  end

  @impl true
  @spec remove(ref(), term()) :: :ok | {:error, term()}
  def remove({table, shadow}, key) do
    :ets.delete(shadow, key)

    case :dets.delete(table, key) do
      :ok ->
        :dets.sync(table)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec export_all(ref()) :: list()
  def export_all(ref) do
    foldl(ref, [], &[&1 | &2])
  end

  @impl true
  @spec foldl(ref(), term(), (term(), term() -> term())) :: term()
  def foldl({table, shadow}, acc, fun) do
    :dets.foldl(
      fn entry, acc_in ->
        if visible?(shadow, entry), do: fun.(entry, acc_in), else: acc_in
      end,
      acc,
      table
    )
  end

  @impl true
  @spec match(ref(), term()) :: list()
  def match({table, shadow}, match_expr) do
    case :dets.match_object(table, match_expr) do
      {:error, _} ->
        []

      objects when is_list(objects) ->
        objects
        |> Enum.reject(&shadowed?(shadow, elem(&1, 0)))
        |> project(match_expr)
    end
  end

  @impl true
  @spec clear_all(ref()) :: :ok | {:error, term()}
  def clear_all({table, shadow}) do
    case :dets.delete_all_objects(table) do
      :ok ->
        :dets.sync(table)
        :ets.delete_all_objects(shadow)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec read_durable(ref()) :: {:ok, [{term(), term()}]} | {:error, term()}
  def read_durable({table, _shadow}), do: DetsFile.read_durable(table)

  ## Helpers ----------------------------------------------------------------

  # `:dets.insert/2` takes a single object or a list; either way one sync
  # makes the whole write durable.
  defp do_insert({table, shadow}, objects) do
    objects = List.wrap(objects)
    Enum.each(objects, &:ets.delete(shadow, elem(&1, 0)))

    case :dets.insert(table, objects) do
      :ok ->
        :dets.sync(table)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp shadow_existing_keys(table, shadow) do
    :dets.foldl(
      fn entry, acc ->
        :ets.insert(shadow, {elem(entry, 0)})
        acc
      end,
      :ok,
      table
    )
  end

  defp visible_lookup(table, shadow, key) do
    if shadowed?(shadow, key) do
      nil
    else
      table |> :dets.lookup(key) |> List.first()
    end
  end

  defp shadowed?(shadow, key), do: :ets.member(shadow, key)

  defp visible?(shadow, entry) do
    not Entry.expired?(entry) and not shadowed?(shadow, elem(entry, 0))
  end

  # `:dets.match/2` cannot be filtered by key, so reads go through
  # `match_object/2` and re-derive the same `'$N'` projection here.
  defp project([], _match_expr), do: []

  defp project(objects, match_expr) do
    spec = :ets.match_spec_compile([{match_expr, [], [:"$$"]}])

    objects
    |> then(&:ets.match_spec_run(&1, spec))
    |> Enum.map(&List.to_tuple/1)
  end
end
