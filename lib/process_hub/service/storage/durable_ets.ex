defmodule ProcessHub.Service.Storage.DurableEts do
  @moduledoc """
  Hybrid registry storage. Selected via
  `registry_backend: {:durable_ets, opts}` on `ProcessHub.t()`.

  ETS is the source-of-truth for reads and writes; every mutation is
  mirrored to a DETS file with `:dets.sync/1` before returning, so
  durability is no weaker than the `ProcessHub.Service.Storage.Dets`
  backend. On `open/2` the DETS file is replayed into ETS so reads are
  immediately authoritative.

  ### When to use

  Pick this backend when you want the read latency of the `:ets`
  backend (every `child_lookup/2`, `process_list/2`, and
  `start_children` `check_existing` lookup is a single
  `:ets.lookup`) **and** restart-survival of the `{:dets, _}` backend.

  ### File location

  Identical to the `:dets` backend. Default
  `priv/process_hub/<hub_id>/registry.dets`; override with the `:path`
  option:

      registry_backend: {:durable_ets, path: "/var/lib/myapp/hub.dets"}

  The format on disk is a plain DETS file — switching a hub between
  `{:dets, _}` and `{:durable_ets, _}` against the same path picks up
  the existing rows.

  ### Recovery on corruption

  Same rotation behaviour as the DETS backend: on a corrupt file the
  original is moved aside as `<path>.corrupt-<system_monotonic>`,
  telemetry `[:process_hub, :registry, :backend_corrupt]` is emitted,
  and a fresh empty DETS file is opened. The ETS table is empty in
  this case (the rows were not loadable).

  ### Crash semantics

  Between the ETS write and the `:dets.sync/1` return, the row is in
  memory but not durable. On restart, the ETS table is rebuilt from
  the DETS file — an inflight write is lost. Identical to the DETS
  backend's existing crash window.

  On a DETS-write error (e.g. underlying volume becomes read-only),
  the just-inserted ETS row is rolled back via `:ets.delete/2` so
  observers see consistent state and the call returns
  `{:error, reason}`.

  ### TTL

  Same as the DETS backend. Entries inserted with `:ttl` are stored
  as `{key, value, expire_ms}` in both ETS and DETS; reads filter
  expired entries on the way out.
  """

  @behaviour ProcessHub.Service.Storage.Behaviour

  alias :ets, as: ETS

  @type ref() :: {:ets.tid(), atom()}

  @impl true
  @spec open(atom(), keyword()) :: {:ok, ref()} | {:error, term()}
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
      {:ok, dets_table} ->
        ets_tid = ETS.new(:durable_ets_registry, [:set, :public, read_concurrency: true])
        replay_into_ets(dets_table, ets_tid)
        emit_opened(hub_id, dets_table, path, repaired?)
        {:ok, {ets_tid, dets_table}}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  @spec close(ref()) :: :ok
  def close({ets_tid, dets_table}) do
    case ETS.info(ets_tid) do
      :undefined -> :ok
      _ -> ETS.delete(ets_tid)
    end

    case :dets.close(dets_table) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  @impl true
  @spec insert(ref(), term(), term()) :: :ok | {:error, term()}
  def insert(ref, key, value) do
    do_write(ref, key, {key, value})
  end

  @impl true
  @spec insert(ref(), term(), term(), keyword()) :: :ok | {:error, term()}
  def insert(ref, key, value, opts) do
    object =
      case Keyword.get(opts, :ttl) do
        ttl when is_integer(ttl) ->
          expire = DateTime.utc_now() |> DateTime.to_unix(:millisecond) |> Kernel.+(ttl)
          {key, value, expire}

        _ ->
          {key, value}
      end

    do_write(ref, key, object)
  end

  @impl true
  @spec get(ref(), term()) :: term() | nil
  def get({ets_tid, _dets}, key) do
    case ETS.lookup(ets_tid, key) do
      [] -> nil
      [{_key, value, expire} | _] -> if past?(expire), do: nil, else: value
      [{_key, value} | _] -> value
    end
  end

  @impl true
  @spec exists?(ref(), term()) :: boolean()
  def exists?({ets_tid, _dets}, key) do
    case ETS.lookup(ets_tid, key) do
      [] -> false
      [entry | _] -> not expired?(entry)
    end
  end

  @impl true
  @spec remove(ref(), term()) :: :ok | {:error, term()}
  def remove({ets_tid, dets_table} = _ref, key) do
    prior = ETS.lookup(ets_tid, key)
    ETS.delete(ets_tid, key)

    case :dets.delete(dets_table, key) do
      :ok ->
        emit(:remove, %{count: 1}, %{hub_id: dets_table, child_id: key})
        :dets.sync(dets_table)
        :ok

      {:error, reason} ->
        # Roll back the ETS deletion so the in-memory state matches
        # the on-disk state.
        Enum.each(prior, &ETS.insert(ets_tid, &1))
        {:error, reason}
    end
  end

  @impl true
  @spec export_all(ref()) :: list()
  def export_all({ets_tid, _dets}) do
    ETS.foldl(
      fn entry, acc ->
        if expired?(entry), do: acc, else: [entry | acc]
      end,
      [],
      ets_tid
    )
  end

  @impl true
  @spec foldl(ref(), term(), (term(), term() -> term())) :: term()
  def foldl({ets_tid, _dets}, acc, fun) do
    ETS.foldl(
      fn entry, acc_in ->
        if expired?(entry), do: acc_in, else: fun.(entry, acc_in)
      end,
      acc,
      ets_tid
    )
  end

  @impl true
  @spec match(ref(), term()) :: list()
  def match({ets_tid, _dets}, match_expr) do
    ets_tid
    |> ETS.match(match_expr)
    |> Enum.map(&List.to_tuple/1)
  end

  @impl true
  @spec clear_all(ref()) :: :ok | {:error, term()}
  def clear_all({ets_tid, dets_table} = _ref) do
    case :dets.delete_all_objects(dets_table) do
      :ok ->
        :dets.sync(dets_table)
        ETS.delete_all_objects(ets_tid)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Helpers ----------------------------------------------------------------

  defp do_write({ets_tid, dets_table}, key, object) do
    prior = ETS.lookup(ets_tid, key)
    ETS.insert(ets_tid, object)

    case :dets.insert(dets_table, object) do
      :ok ->
        emit(:insert, %{count: 1}, %{hub_id: dets_table, child_id: key})
        :dets.sync(dets_table)
        :ok

      {:error, reason} ->
        # Roll back the in-memory write to keep ETS and DETS consistent.
        ETS.delete(ets_tid, key)
        Enum.each(prior, &ETS.insert(ets_tid, &1))
        {:error, reason}
    end
  end

  defp replay_into_ets(dets_table, ets_tid) do
    :dets.foldl(
      fn entry, acc ->
        if expired?(entry), do: acc, else: ETS.insert(ets_tid, entry)
        acc
      end,
      :ok,
      dets_table
    )
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
    rotated = "#{path}.corrupt-#{System.monotonic_time()}"
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

  defp emit_opened(hub_id, dets_table, path, repaired?) do
    row_count =
      try do
        :dets.info(dets_table, :size) || 0
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

  defp expired?({_key, _value, expire}), do: past?(expire)
  defp expired?(_other), do: false

  defp past?(expire) when is_integer(expire) do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    now > expire
  end

  defp past?(_), do: false
end
