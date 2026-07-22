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
  an error is logged, and a fresh empty DETS file is opened. The ETS table is empty in
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
  alias ProcessHub.Service.Storage.DetsFile
  alias ProcessHub.Service.Storage.Entry

  @type ref() :: {:ets.tid(), atom()}

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
      {:ok, dets_table} ->
        ets_tid = ETS.new(:durable_ets_registry, [:set, :public, read_concurrency: true])
        if replay?, do: replay_into_ets(dets_table, ets_tid)
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
    do_write(ref, [{key, value}])
  end

  @impl true
  @spec insert(ref(), term(), term(), keyword()) :: :ok | {:error, term()}
  def insert(ref, key, value, opts) do
    do_write(ref, [Entry.build(key, value, opts)])
  end

  @impl true
  @spec insert_many(ref(), [{term(), term(), keyword()}]) :: :ok | {:error, term()}
  def insert_many(ref, items) do
    do_write(ref, Entry.build_many(items))
  end

  @impl true
  @spec get(ref(), term()) :: term() | nil
  def get({ets_tid, _dets}, key) do
    case ETS.lookup(ets_tid, key) do
      [] -> nil
      [entry | _] -> Entry.value(entry)
    end
  end

  @impl true
  @spec exists?(ref(), term()) :: boolean()
  def exists?({ets_tid, _dets}, key) do
    case ETS.lookup(ets_tid, key) do
      [] -> false
      [entry | _] -> not Entry.expired?(entry)
    end
  end

  @impl true
  @spec remove(ref(), term()) :: :ok | {:error, term()}
  def remove({ets_tid, dets_table} = _ref, key) do
    prior = ETS.lookup(ets_tid, key)
    ETS.delete(ets_tid, key)

    case :dets.delete(dets_table, key) do
      :ok ->
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
        if Entry.expired?(entry), do: acc, else: [entry | acc]
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
        if Entry.expired?(entry), do: acc_in, else: fun.(entry, acc_in)
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

  defp do_write({ets_tid, dets_table}, objects) do
    keys = Enum.map(objects, &elem(&1, 0))
    prior = Enum.flat_map(keys, &ETS.lookup(ets_tid, &1))
    ETS.insert(ets_tid, objects)

    case :dets.insert(dets_table, objects) do
      :ok ->
        :dets.sync(dets_table)
        :ok

      {:error, reason} ->
        # Roll back the in-memory writes to keep ETS and DETS consistent.
        Enum.each(keys, &ETS.delete(ets_tid, &1))
        Enum.each(prior, &ETS.insert(ets_tid, &1))
        {:error, reason}
    end
  end

  defp replay_into_ets(dets_table, ets_tid) do
    :dets.foldl(
      fn entry, acc ->
        if Entry.expired?(entry), do: acc, else: ETS.insert(ets_tid, entry)
        acc
      end,
      :ok,
      dets_table
    )
  end
end
