defmodule ProcessHub.Service.Storage do
  @moduledoc """
  Local storage service. Provides API functions for managing local
  storage used by ProcessHub for three concerns:

    * **Misc storage** — strategy configs, runtime state. Always ETS.
    * **Hook storage** — registered hook handlers. Always ETS.
    * **Process registry** — child registrations. Routed through the
      configured `ProcessHub.Service.Storage.Behaviour` backend
      (default `ProcessHub.Service.Storage.Ets`).

  When a registry backend is opened it registers itself with this
  module via `register_backend/3`. From then on, calls to the public
  API that target a registry table (the hub_id atom) are dispatched
  through the configured backend module. Misc and hook storage
  (passed by tid) bypass the dispatcher and use ETS directly.

  The public function signatures and return values are unchanged from
  prior releases.
  """

  alias :ets, as: ETS
  alias ProcessHub.Service.Storage.Ets, as: EtsBackend

  @type table_id() :: atom() | :ets.tid()

  @persistent_term_namespace :process_hub_registry_backend

  @doc """
  Registers `{module, ref}` as the registry backend for `hub_id`.

  After registration, public API calls passing `hub_id` (an atom) are
  dispatched through `module`. Called by the coordinator at startup.
  """
  @spec register_backend(atom(), module(), term()) :: :ok
  def register_backend(hub_id, module, ref) when is_atom(hub_id) and is_atom(module) do
    :persistent_term.put({@persistent_term_namespace, hub_id}, {module, ref})
    :ok
  end

  @doc """
  Removes the registered backend for `hub_id`. Called by the
  coordinator at shutdown.
  """
  @spec unregister_backend(atom()) :: :ok
  def unregister_backend(hub_id) when is_atom(hub_id) do
    :persistent_term.erase({@persistent_term_namespace, hub_id})
    :ok
  end

  @doc """
  Returns `{module, ref}` for the registered registry backend, or
  `nil` if `hub_id` has no registered backend.
  """
  @spec registered_backend(atom()) :: {module(), term()} | nil
  def registered_backend(hub_id) when is_atom(hub_id) do
    :persistent_term.get({@persistent_term_namespace, hub_id}, nil)
  end

  def registered_backend(_), do: nil

  @doc "Returns a boolean indicating whether the key exists in local storage."
  @spec exists?(table_id(), term()) :: boolean()
  def exists?(table, key) do
    case registered_backend(table) do
      nil -> EtsBackend.exists?(table, key)
      {module, ref} -> module.exists?(ref, key)
    end
  end

  @doc """
  Returns the value for the key in local storage.

  If the key does not exist, nil is returned; otherwise, the value is returned in
  the format of a tuple: `{key, value, ttl}`.
  """
  @spec get(table_id(), term()) :: term()
  def get(table, key) do
    case registered_backend(table) do
      nil -> EtsBackend.get(table, key)
      {module, ref} -> module.get(ref, key)
    end
  end

  @doc """
  Matches the given expression against the storage table.

  The `match_expr` is a tuple that specifies the pattern.
  """
  @spec match(table_id(), term()) :: term()
  def match(table, match_expr) do
    case registered_backend(table) do
      nil -> EtsBackend.match(table, match_expr)
      {module, ref} -> module.match(ref, match_expr)
    end
  end

  @doc """
  Updates the value for the key in local storage.

  The `func` function is expected to take the current value as an argument and
  return the new value.

  If the key does not exist, the current value is nil.
  """
  @spec update(table_id(), term(), function()) :: boolean()
  def update(table, key, func) do
    insert(table, key, func.(get(table, key)))
    true
  end

  @doc """
  Inserts the key and value into local storage.

  Available options:
    - `ttl`: The time to live for the key in milliseconds.
  """
  @spec insert(table_id(), term(), term(), keyword() | nil) :: boolean() | :ok
  def insert(table, key, value, opts \\ []) do
    case registered_backend(table) do
      nil ->
        EtsBackend.insert(table, key, value, opts || [])
        true

      {module, ref} ->
        module.insert(ref, key, value, opts || [])
    end
  end

  @doc """
  Inserts a batch of `{key, value, opts}` items.

  Backends implementing the optional `insert_many/2` callback commit the
  whole batch with a single write, so concurrent readers never observe a
  partially applied batch. Other backends fall back to per-item inserts.
  """
  @spec insert_many(table_id(), [{term(), term(), keyword()}]) :: :ok | {:error, term()}
  def insert_many(_table, []), do: :ok

  def insert_many(table, items) do
    case registered_backend(table) do
      nil ->
        EtsBackend.insert_many(table, items)

      {module, ref} ->
        if function_exported?(module, :insert_many, 2) do
          module.insert_many(ref, items)
        else
          Enum.each(items, fn {key, value, opts} -> module.insert(ref, key, value, opts) end)
        end
    end
  end

  @doc """
  Removes an entry from the storage.
  """
  @spec remove(table_id(), term()) :: boolean() | :ok
  def remove(table, key) do
    case registered_backend(table) do
      nil ->
        ETS.delete(table, key)

      {module, ref} ->
        module.remove(ref, key)
    end
  end

  @doc """
  Deletes all objects from the storage table.

  Never use in custom code. Should only be used for testing purposes.
  """
  @spec clear_all(table_id()) :: boolean() | :ok
  def clear_all(table) do
    case registered_backend(table) do
      nil ->
        ETS.delete_all_objects(table)

      {module, ref} ->
        module.clear_all(ref)
    end
  end

  @doc "Exports all objects from the storage table."
  @spec export_all(table_id()) :: [{atom() | binary(), term(), pos_integer() | nil}]
  def export_all(table) do
    case registered_backend(table) do
      nil -> EtsBackend.export_all(table)
      {module, ref} -> module.export_all(ref)
    end
  end

  @doc """
  Folds over all objects in the storage table with a function.

  More memory efficient than export_all + filter for large tables
  as it doesn't create an intermediate copy of the entire table.
  """
  @spec foldl(table_id(), acc, (term(), acc -> acc)) :: acc when acc: term()
  def foldl(table, acc, fun) do
    case registered_backend(table) do
      nil -> EtsBackend.foldl(table, acc, fun)
      {module, ref} -> module.foldl(ref, acc, fun)
    end
  end

  @doc """
  Folds over all objects as `{key, value}`, dropping the trailing TTL element
  that entries inserted with a `:ttl` carry.
  """
  @spec foldl_entries(table_id(), acc, ({term(), term()}, acc -> acc)) :: acc when acc: term()
  def foldl_entries(table, acc, fun) do
    foldl(table, acc, fn
      {key, value}, acc -> fun.({key, value}, acc)
      {key, value, _ttl}, acc -> fun.({key, value}, acc)
    end)
  end
end
