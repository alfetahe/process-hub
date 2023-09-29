defmodule ProcessHub.Service.LocalStorage do
  @moduledoc """
  The local storage service provides API functions for managing local storage.
  This is mainly used for storing data that is not required to be persisted.

  Local storage is implemented using ETS tables and is cleared periodically.
  """

  @doc "Returns a boolean indicating whether the key exists in local storage."
  @spec exists?(ProcessHub.hub_id() | :ets.tid(), term()) :: boolean()
  def exists?(hub_id, key) do
    result = get(hub_id, key)

    case result do
      nil ->
        false

      _ ->
        true
    end
  end

  @doc """
  Returns the value for the key in local storage.

  If the key does not exist, nil is returned; otherwise, the value is returned in
  the format of a tuple: `{key, value, ttl}`.
  """
  @spec get(ProcessHub.hub_id() | :ets.tid(), term()) :: term()
  def get(hub_id, key) do
    :ets.lookup(hub_id, key)
    |> List.first()
  end

  @doc """
  Inserts the key and value into local storage.

  It is possible to set a time to live (TTL) for the key. If the TTL is set to
  nil, the key will not expire.

  The `ttl` value is expected to be a positive integer in milliseconds or `nil`.
  """
  @spec insert(ProcessHub.hub_id() | :ets.tid(), term(), term(), pos_integer() | nil) :: true
  def insert(hub_id, key, value, ttl \\ nil) do
    :ets.insert(hub_id, {key, value, set_ttl(ttl)})
  end

  defp set_ttl(ttl_val) when is_number(ttl_val) do
    DateTime.utc_now() |> DateTime.add(ttl_val, :millisecond) |> DateTime.to_unix()
  end

  defp set_ttl(_ttl_val) do
    nil
  end
end
