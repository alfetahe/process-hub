defmodule ProcessHub.Service.Storage do
  @moduledoc """
  The local storage service provides API functions for managing local storage.
  This is mainly used for storing data that is not required to be persisted.

  Local storage is implemented using ETS tables and is cleared periodically.
  """

  alias :ets, as: ETS

  @type table_id() :: atom()

  @doc "Returns a boolean indicating whether the key exists in local storage."
  @spec exists?(table_id(), term()) :: boolean()
  def exists?(table, key) do
    case ETS.lookup(table, key) do
      [] -> false
      _ -> true
    end
  end

  @doc """
  Returns the value for the key in local storage.

  If the key does not exist, nil is returned; otherwise, the value is returned in
  the format of a tuple: `{key, value, ttl}`.
  """
  @spec get(table_id(), term()) :: term()
  def get(table, key) do
    item =
      table
      |> ETS.lookup(key)
      |> List.first()

    case item do
      {_key, value, _ttl} -> value
      {_key, value} -> value
      _ -> nil
    end
  end

  @doc """
  Matches the given expression against the ETS table.

  The `match_expr` is a tuple that specifies the pattern.
  """
  @spec match(table_id(), term()) :: term()
  def match(table, match_expr) do
    table
    |> ETS.match(match_expr)
    |> Enum.map(fn list_matches -> List.to_tuple(list_matches) end)
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
  end

  @doc """
  Inserts the key and value into local storage.

  Available options:
    - `ttl`: The time to live for the key in milliseconds.
  """
  @spec insert(table_id(), term(), term(), keyword() | nil) :: boolean()
  def insert(table, key, value, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, nil)

    case is_integer(ttl) do
      true ->
        expire = (DateTime.utc_now() |> DateTime.to_unix(:millisecond)) + ttl
        ETS.insert(table, {key, value, expire})

      false ->
        ETS.insert(table, {key, value})
    end
  end

  @doc """
  Removes an entry from the storage.
  """
  @spec remove(table_id(), term()) :: boolean()
  def remove(table, key) do
    ETS.delete(table, key)
  end

  @doc """
  Deletes all objects from the ETS table.

  Never use in custom code. Should only be used for testing purposes.
  """
  @spec clear_all(table_id()) :: boolean()
  def clear_all(table) do
    ETS.delete_all_objects(table)
  end

  @doc "Exports all objects from the ETS table."
  @spec export_all(table_id()) :: [{atom() | binary(), term(), pos_integer() | nil}]
  def export_all(table) do
    ETS.tab2list(table)
  end
end
