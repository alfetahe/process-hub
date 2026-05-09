defmodule ProcessHub.Service.Storage.Behaviour do
  @moduledoc """
  Behaviour contract for ProcessHub registry storage backends.

  A backend module implements the registry-table operations used by
  `ProcessHub.Service.ProcessRegistry`. The default backend is
  `ProcessHub.Service.Storage.Ets` (in-memory ETS). The opt-in DETS
  backend (`ProcessHub.Service.Storage.Dets`) provides on-disk
  persistence so the registry survives a coordinator restart.

  All mutating callbacks return `:ok | {:error, term()}` rather than
  booleans so a backend that may fail synchronously (timeout, no quorum,
  IO error) can signal that without API churn. Read callbacks return
  the value directly.

  The `t:ref/0` returned by `c:open/2` is opaque to callers; each
  backend chooses its own representation (an ETS tid, a DETS table
  name, a custom client handle, etc.).
  """

  @typedoc """
  An opaque handle returned by `c:open/2`. Backends choose their own
  representation; callers MUST treat it as opaque.
  """
  @type ref() :: term()

  @typedoc """
  Options accepted by `c:insert/4`.

    * `:ttl` — time-to-live in milliseconds. When set, the entry is
      stored as `{key, value, expire_ms}` and reads filter expired
      entries.
  """
  @type insert_opts() :: [{:ttl, pos_integer()}] | keyword()

  @doc """
  Opens (and if necessary creates) the registry storage for the given
  hub.

  `opts` is a backend-specific keyword list. Returns `{:ok, ref}` on
  success or `{:error, reason}` on unrecoverable failure.
  """
  @callback open(hub_id :: atom(), opts :: keyword()) :: {:ok, ref()} | {:error, term()}

  @doc """
  Closes the registry storage. Implementations MUST flush any pending
  writes before returning.
  """
  @callback close(ref :: ref()) :: :ok

  @doc """
  Inserts `value` under `key`. Returns `:ok` once the write is durable
  for the backend's durability model (synchronous for DETS, in-memory
  for ETS).
  """
  @callback insert(ref :: ref(), key :: term(), value :: term()) :: :ok | {:error, term()}

  @doc """
  Inserts `value` under `key` with options.

  Supported `opts`:

    * `:ttl` — milliseconds until the entry is considered expired.
      Stored as `{key, value, expire_ms}`; reads filter expired entries.
  """
  @callback insert(ref :: ref(), key :: term(), value :: term(), opts :: insert_opts()) ::
              :ok | {:error, term()}

  @doc """
  Returns the value stored under `key`, or `nil` if the key is missing
  or expired.
  """
  @callback get(ref :: ref(), key :: term()) :: term() | nil

  @doc """
  Returns `true` when `key` is present (and not expired).
  """
  @callback exists?(ref :: ref(), key :: term()) :: boolean()

  @doc """
  Removes `key`.
  """
  @callback remove(ref :: ref(), key :: term()) :: :ok | {:error, term()}

  @doc """
  Returns all entries as a list. The shape mirrors the existing
  `:ets.tab2list/1` output: 2-tuples for entries without TTL and
  3-tuples for entries with TTL. Expired entries are filtered.
  """
  @callback export_all(ref :: ref()) :: list()

  @doc """
  Folds `fun` over all entries with initial accumulator `acc`.
  """
  @callback foldl(ref :: ref(), acc :: term(), fun :: (term(), term() -> term())) :: term()

  @doc """
  Returns the list of matches for `match_expr`. The shape matches the
  current `ProcessHub.Service.Storage.match/2` (a list of tuples, not a
  list of lists).
  """
  @callback match(ref :: ref(), match_expr :: term()) :: list()

  @doc """
  Removes all entries.
  """
  @callback clear_all(ref :: ref()) :: :ok
end
