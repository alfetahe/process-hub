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

  @impl true
  @spec open(atom(), keyword()) :: {:ok, atom()} | {:error, term()}
  def open(hub_id, opts) when is_atom(hub_id) do
    path = resolve_path(hub_id, opts)
    File.mkdir_p!(Path.dirname(path))

    {result, repaired?} =
      case :dets.open_file(hub_id, file: to_charlist(path), repair: true, type: :set) do
        {:ok, table} ->
          {{:ok, table}, false}

        {:error, reason} ->
          rotate_and_reopen(hub_id, path, reason)
      end

    case result do
      {:ok, table} ->
        emit_opened(hub_id, table, path, repaired?)
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
    do_insert(ref, key, {key, value})
  end

  @impl true
  @spec insert(atom(), term(), term(), keyword()) :: :ok | {:error, term()}
  def insert(ref, key, value, opts) do
    object =
      case Keyword.get(opts, :ttl) do
        ttl when is_integer(ttl) ->
          expire = DateTime.utc_now() |> DateTime.to_unix(:millisecond) |> Kernel.+(ttl)
          {key, value, expire}

        _ ->
          {key, value}
      end

    do_insert(ref, key, object)
  end

  @impl true
  @spec get(atom(), term()) :: term() | nil
  def get(ref, key) do
    case :dets.lookup(ref, key) do
      [] -> nil
      [entry | _] -> from_entry(entry)
    end
  end

  @impl true
  @spec exists?(atom(), term()) :: boolean()
  def exists?(ref, key) do
    case :dets.lookup(ref, key) do
      [] -> false
      [entry | _] -> not expired?(entry)
    end
  end

  @impl true
  @spec remove(atom(), term()) :: :ok | {:error, term()}
  def remove(ref, key) do
    case :dets.delete(ref, key) do
      :ok ->
        emit(:remove, %{count: 1}, %{hub_id: ref, child_id: key})
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
        if expired?(entry), do: acc, else: [entry | acc]
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
        if expired?(entry), do: acc_in, else: fun.(entry, acc_in)
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

  defp do_insert(ref, key, object) do
    case :dets.insert(ref, object) do
      :ok ->
        emit(:insert, %{count: 1}, %{hub_id: ref, child_id: key})
        :dets.sync(ref)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_path(hub_id, opts) do
    case Keyword.get(opts, :path) do
      nil -> default_path(hub_id)
      path when is_binary(path) -> path
      path when is_list(path) -> List.to_string(path)
    end
  end

  defp default_path(hub_id) do
    base =
      case :code.priv_dir(:process_hub) do
        {:error, :bad_name} -> Path.join([File.cwd!(), "priv"])
        priv when is_list(priv) -> List.to_string(priv)
      end

    Path.join([base, "process_hub", Atom.to_string(hub_id), "registry.dets"])
  end

  defp rotate_and_reopen(hub_id, path, reason) do
    rotated =
      "#{path}.corrupt-#{System.monotonic_time()}"

    _ = File.rename(path, rotated)

    emit(:backend_corrupt, %{}, %{
      hub_id: hub_id,
      path: path,
      rotated_to: rotated,
      reason: reason
    })

    case :dets.open_file(hub_id, file: to_charlist(path), repair: true, type: :set) do
      {:ok, table} -> {{:ok, table}, true}
      {:error, _} = err -> {err, false}
    end
  end

  defp emit_opened(hub_id, _table, path, repaired?) do
    row_count =
      try do
        :dets.info(hub_id, :size) || 0
      rescue
        _ -> 0
      end

    emit(:backend_opened, %{row_count: row_count, elapsed_ms: 0}, %{
      hub_id: hub_id,
      backend: __MODULE__,
      path: path,
      repaired: repaired?
    })
  end

  defp emit(event, measurements, metadata) do
    :telemetry.execute([:process_hub, :registry, event], measurements, metadata)
  rescue
    UndefinedFunctionError -> :ok
    ArgumentError -> :ok
  end

  defp from_entry({_key, value}), do: value

  defp from_entry({_key, value, expire}) do
    if past?(expire), do: nil, else: value
  end

  defp expired?({_key, _value, expire}), do: past?(expire)
  defp expired?(_other), do: false

  defp past?(expire) when is_integer(expire) do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    now > expire
  end

  defp past?(_), do: false
end
