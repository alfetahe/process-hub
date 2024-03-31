defmodule ProcessHub.Service.LocalStorage do
  @moduledoc """
  The local storage service provides API functions for managing local storage.
  This is mainly used for storing data that is not required to be persisted.

  Local storage is implemented using ETS tables and is cleared periodically.
  """

  alias ProcessHub.Utility.Name

  @doc "Returns a boolean indicating whether the key exists in local storage."
  @spec exists?(ProcessHub.hub_id(), term()) :: boolean()
  def exists?(hub_id, key) do
    {:ok, result} = Cachex.exists?(Name.local_storage(hub_id), key)

    result
  end

  @doc """
  Returns the value for the key in local storage.

  If the key does not exist, nil is returned; otherwise, the value is returned in
  the format of a tuple: `{key, value, ttl}`.
  """
  @spec get(ProcessHub.hub_id(), term()) :: term()
  def get(hub_id, key) do
    {:ok, value} = Cachex.get(Name.local_storage(hub_id), key)

    value
  end

  @doc """
  Updates the value for the key in local storage.

  The `func` function is expected to take the current value as an argument and
  return the new value.

  If the key does not exist, the current value is nil.
  """
  @spec update(ProcessHub.hub_id(), term(), function()) :: {:commit, any()}
  def update(hub_id, key, func) do
    Cachex.get_and_update(Name.local_storage(hub_id), key, fn
      value -> {:commit, func.(value)}
    end)
  end

  @doc """
  Inserts the key and value into local storage.

  It is possible to set a time to live (TTL) for the key. If the TTL is set to
  nil, the key will not expire.

  The `ttl` value is expected to be a positive integer in milliseconds.
  """
  @spec insert(ProcessHub.hub_id(), term(), term(), pos_integer() | nil) :: boolean()
  def insert(hub_id, key, value, ttl) do
    {:ok, res} = Cachex.put(Name.local_storage(hub_id), key, value, ttl: ttl)

    res
  end

  def insert(hub_id, key, value) do
    {:ok, res} = Cachex.put(Name.local_storage(hub_id), key, value)

    res
  end
end
