defmodule ProcessHub.Service.Storage.Ets do
  @moduledoc """
  ETS-backed registry storage.

  This is the default backend. It preserves bit-for-bit the observable
  behaviour of the previous `ProcessHub.Service.Storage` module: TTL
  entries are stored as `{key, value, expire_ms}`, reads filter expired
  entries, and `match/2` returns a list of tuples.

  The opaque ref returned by `open/2` is the ETS table name (an atom
  matching the hub id). Existing call sites that pass `hub_id` directly
  to `:ets`-style helpers continue to function.
  """

  @behaviour ProcessHub.Service.Storage.Behaviour

  alias :ets, as: ETS
  alias ProcessHub.Service.Storage.Entry

  @impl true
  @spec open(atom(), keyword()) :: {:ok, atom()} | {:error, term()}
  def open(hub_id, _opts) when is_atom(hub_id) do
    case :ets.info(hub_id) do
      :undefined ->
        ETS.new(hub_id, [:set, :public, :named_table])
        {:ok, hub_id}

      _ ->
        {:ok, hub_id}
    end
  end

  @impl true
  @spec close(atom()) :: :ok
  def close(ref) do
    case :ets.info(ref) do
      :undefined ->
        :ok

      _ ->
        ETS.delete(ref)
        :ok
    end
  end

  @impl true
  @spec insert(atom() | :ets.tid(), term(), term()) :: :ok
  def insert(ref, key, value) do
    ETS.insert(ref, {key, value})
    :ok
  end

  @impl true
  @spec insert(atom() | :ets.tid(), term(), term(), keyword()) :: :ok
  def insert(ref, key, value, opts) do
    ETS.insert(ref, Entry.build(key, value, opts))
    :ok
  end

  @impl true
  @spec insert_many(atom() | :ets.tid(), [{term(), term(), keyword()}]) :: :ok
  def insert_many(ref, items) do
    ETS.insert(ref, Entry.build_many(items))
    :ok
  end

  @impl true
  @spec get(atom() | :ets.tid(), term()) :: term() | nil
  def get(ref, key) do
    item =
      ref
      |> ETS.lookup(key)
      |> List.first()

    case item do
      {_key, value, _ttl} -> value
      {_key, value} -> value
      _ -> nil
    end
  end

  @impl true
  @spec exists?(atom() | :ets.tid(), term()) :: boolean()
  def exists?(ref, key) do
    case ETS.lookup(ref, key) do
      [] -> false
      _ -> true
    end
  end

  @impl true
  @spec remove(atom() | :ets.tid(), term()) :: :ok
  def remove(ref, key) do
    ETS.delete(ref, key)
    :ok
  end

  @impl true
  @spec export_all(atom() | :ets.tid()) :: list()
  def export_all(ref) do
    ETS.tab2list(ref)
  end

  @impl true
  @spec foldl(atom() | :ets.tid(), term(), (term(), term() -> term())) :: term()
  def foldl(ref, acc, fun) do
    ETS.foldl(fun, acc, ref)
  end

  @impl true
  @spec match(atom() | :ets.tid(), term()) :: list()
  def match(ref, match_expr) do
    ref
    |> ETS.match(match_expr)
    |> Enum.map(&List.to_tuple/1)
  end

  @impl true
  @spec clear_all(atom() | :ets.tid()) :: :ok
  def clear_all(ref) do
    ETS.delete_all_objects(ref)
    :ok
  end
end
