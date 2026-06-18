defmodule ProcessHub.Service.Storage.Entry do
  @moduledoc """
  The stored-entry value object shared by every registry storage backend.

  An entry is a `{key, value}` tuple, or `{key, value, expire_ms}` when it
  carries a TTL. These helpers build entries on write and read their value back
  on read (filtering expired ones), independent of where the entry is persisted
  (ETS, DETS, a future remote store, ...).
  """

  @doc "Builds the entry for `key`/`value`, attaching an ms expiry when `opts` has an integer `:ttl`."
  @spec build(term(), term(), keyword()) :: {term(), term()} | {term(), term(), integer()}
  def build(key, value, opts) do
    case Keyword.get(opts, :ttl) do
      ttl when is_integer(ttl) ->
        expire = DateTime.utc_now() |> DateTime.to_unix(:millisecond) |> Kernel.+(ttl)
        {key, value, expire}

      _ ->
        {key, value}
    end
  end

  @doc "Returns an entry's stored value, or `nil` if it has expired."
  @spec value(tuple()) :: term() | nil
  def value({_key, value}), do: value
  def value({_key, value, expire}), do: if(past?(expire), do: nil, else: value)

  @doc "Returns whether an entry has passed its TTL expiry."
  @spec expired?(tuple()) :: boolean()
  def expired?({_key, _value, expire}), do: past?(expire)
  def expired?(_other), do: false

  defp past?(expire) when is_integer(expire) do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    now > expire
  end

  defp past?(_), do: false
end
