defmodule ProcessHub.Service.LocalStorage do
  @moduledoc """
  The local storage service provides API functions for managing local storage.
  This is mainly used for storing data that is not required to be persisted.

  Local storage is implemented using ETS tables and is cleared periodically.
  """

  @doc "Returns a boolean indicating whether the key exists in local storage."
  @spec exists?(ProcessHub.hub_id(), term()) :: boolean()
  def exists?(hub_id, key) do
    {:ok, result} = Cachex.exists?(hub_id, key)

    result
  end

  @doc """
  Returns the value for the key in local storage.

  If the key does not exist, nil is returned; otherwise, the value is returned in
  the format of a tuple: `{key, value, ttl}`.
  """
  @spec get(ProcessHub.hub_id(), term()) :: term()
  def get(hub_id, key) do
    {:ok, value} = Cachex.get(hub_id, key)

    value
  end

  @doc """
  Inserts the key and value into local storage.

  It is possible to set a time to live (TTL) for the key. If the TTL is set to
  nil, the key will not expire.

  The `ttl` value is expected to be a positive integer in milliseconds.
  """
  @spec insert(ProcessHub.hub_id(), term(), term(), pos_integer() | nil) :: boolean()
  def insert(hub_id, key, value, ttl) do
    {:ok, res} = Cachex.put(hub_id, key, value, ttl: ttl)

    res
  end

  def insert(hub_id, key, value) do
    Cachex.put(hub_id, key, value)
  end
end
