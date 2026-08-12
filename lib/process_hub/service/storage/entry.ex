defmodule ProcessHub.Service.Storage.Entry do
  @moduledoc """
  The stored-entry value object shared by every registry storage backend.

  An entry is a `{key, value}` tuple, or `{key, value, expire_ms}` when it
  carries a TTL. These helpers build entries on write and read their value back
  on read (filtering expired ones), independent of where the entry is persisted
  (ETS, DETS, a future remote store, ...).
  """

  @doc """
  Builds the entry for `key`/`value`, attaching an ms expiry when `opts` carries one.

  Two forms are accepted, `:expire_at` taking precedence:

    * `:expire_at` — an absolute deadline in ms since the unix epoch. Used where
      the deadline is derived from a replicated field (a stopped row's
      `stopped_at`), so every node computes the same value and re-writing the
      entry cannot extend its lifetime.
    * `:ttl` — a duration in ms, resolved against the current time.
  """
  @spec build(term(), term(), keyword()) :: {term(), term()} | {term(), term(), integer()}
  def build(key, value, opts) do
    case {Keyword.get(opts, :expire_at), Keyword.get(opts, :ttl)} do
      {expire, _} when is_integer(expire) ->
        {key, value, expire}

      {_, ttl} when is_integer(ttl) ->
        {key, value, now_ms() + ttl}

      _ ->
        {key, value}
    end
  end

  @doc "Builds entries for a batch of `{key, value, opts}` items (see `build/3`)."
  @spec build_many([{term(), term(), keyword()}]) :: [tuple()]
  def build_many(items) do
    Enum.map(items, fn {key, value, opts} -> build(key, value, opts) end)
  end

  @doc "Returns an entry's stored value, or `nil` if it has expired."
  @spec value(tuple()) :: term() | nil
  def value({_key, value}), do: value
  def value({_key, value, expire}), do: if(past?(expire), do: nil, else: value)

  @doc "Returns whether an entry has passed its TTL expiry."
  @spec expired?(tuple()) :: boolean()
  def expired?({_key, _value, expire}), do: past?(expire)
  def expired?(_other), do: false

  @doc "Current time in ms since the unix epoch, the unit every expiry is expressed in."
  @spec now_ms() :: integer()
  def now_ms, do: DateTime.utc_now() |> DateTime.to_unix(:millisecond)

  defp past?(expire) when is_integer(expire), do: now_ms() > expire

  defp past?(_), do: false
end
