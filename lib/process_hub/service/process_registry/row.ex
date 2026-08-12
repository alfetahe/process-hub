defmodule ProcessHub.Service.ProcessRegistry.Row do
  @moduledoc """
  The registry row's ProcessHub-owned bookkeeping, stored under the reserved
  metadata key `:__process_hub__`.

  A registry row is `{child_spec, node_pids, metadata}`. `child_spec` and
  `node_pids` are the caller's and the cluster's; `metadata` is the caller's
  except for this one reserved key, which is the hub's:

      %{
        epoch: pos_integer(),          # per-child counter, never a wall clock
        lifecycle: :running | :stopped,
        changed_at: integer(),         # diagnostics only
        changed_by: node(),
        stopped_at: integer()          # only while :stopped
      }

  This module is the algebra over that key: who wins a merge, what an authored
  write stamps, when a row expires. It is pure — reads and writes belong to
  `ProcessHub.Service.ProcessRegistry`, which owns the table.

  > #### Experimental {: .warning}
  >
  > The lifecycle and expiry rules are part of the experimental `:auto_recovery`
  > feature and may change in future releases. The epoch and merge ordering apply
  > to every hub.
  """

  alias ProcessHub.Service.Storage.Entry

  @reserved_key :__process_hub__

  @typedoc "The reserved bookkeeping map carried by every row's metadata."
  @type t() :: %{
          :epoch => pos_integer(),
          :lifecycle => lifecycle(),
          :changed_at => integer(),
          :changed_by => node(),
          optional(:stopped_at) => integer()
        }

  @type lifecycle() :: :running | :stopped

  @doc "The reserved metadata key. Hub-owned: caller metadata cannot set it."
  @spec reserved_key() :: :__process_hub__
  def reserved_key, do: @reserved_key

  @doc "Returns a row metadata's bookkeeping, or `nil` for a row that predates it."
  @spec meta(map() | nil) :: t() | nil
  def meta(%{@reserved_key => %{} = meta}), do: meta
  def meta(_), do: nil

  # A row without bookkeeping is epoch 0, so it loses to any stamped row.
  defp epoch(metadata) do
    case meta(metadata) do
      %{epoch: epoch} when is_integer(epoch) -> epoch
      _ -> 0
    end
  end

  @doc "Returns whether a row has been deliberately stopped."
  @spec stopped?(map() | nil) :: boolean()
  def stopped?(metadata) do
    case meta(metadata) do
      %{lifecycle: :stopped} -> true
      _ -> false
    end
  end

  @doc """
  Returns whether `candidate` wins a merge against `incumbent`.

  Resolution is by higher `epoch`, ties broken by the lexicographically lower
  `changed_by` node name, so every node that performs the merge reaches the same
  result in any order and with any number of repetitions.
  """
  @spec wins_merge?(map() | nil, map() | nil) :: boolean()
  def wins_merge?(candidate, incumbent) do
    candidate_epoch = epoch(candidate)
    incumbent_epoch = epoch(incumbent)

    cond do
      candidate_epoch > incumbent_epoch -> true
      candidate_epoch < incumbent_epoch -> false
      true -> changed_by(candidate) < changed_by(incumbent)
    end
  end

  @doc """
  Returns `{metadata, forged?}`: the caller's metadata with the bookkeeping this
  write should carry, and whether the caller tried to author the reserved key.

  `opts[:adopt]` marks a merge — the caller-supplied bookkeeping already won an
  epoch comparison and is written verbatim, because a merge adopts a value rather
  than authoring one. Every other write authors: the epoch advances by one and the
  local node stamps itself. `opts[:lifecycle]` forces the resulting lifecycle;
  without it a bound row is `:running` and an unbound one keeps what it had.

  `forged?` reports on *shape*, not equality. Passing the stored bookkeeping
  straight back is the norm — every read-modify-write does it, and a concurrent
  write in between makes the value legitimately stale — so only a value that is
  not a whole bookkeeping map could have been hand-written. Either way the
  supplied value is ignored.
  """
  @spec stamp(map(), t() | nil, [{node(), pid()}], keyword()) :: {map(), boolean()}
  def stamp(caller_metadata, previous, child_nodes, opts) do
    supplied = meta(caller_metadata)
    metadata = strip(caller_metadata)

    case {Keyword.get(opts, :adopt, false), supplied} do
      {true, %{} = adopted} ->
        {Map.put(metadata, @reserved_key, adopted), false}

      _ ->
        lifecycle = Keyword.get(opts, :lifecycle) || implied_lifecycle(child_nodes, previous)

        {Map.put(metadata, @reserved_key, author(previous, lifecycle)),
         not is_nil(supplied) and not whole?(supplied)}
    end
  end

  @doc """
  Returns the storage entry options for a row: a stopped row expires
  `stopped_row_ttl_ms` after its own `stopped_at`, every other row keeps `opts`
  unchanged.

  The deadline is absolute and derived from a replicated field, so every node that
  adopts the row computes the same value and re-writing it during synchronisation
  cannot extend its lifetime.
  """
  @spec expiry_opts(map(), keyword(), pos_integer()) :: keyword()
  def expiry_opts(metadata, opts, stopped_row_ttl_ms) do
    case meta(metadata) do
      %{lifecycle: :stopped, stopped_at: stopped_at} ->
        Keyword.put(opts, :expire_at, stopped_at + stopped_row_ttl_ms)

      _ ->
        opts
    end
  end

  defp strip(metadata) when is_map(metadata), do: Map.delete(metadata, @reserved_key)
  defp strip(_), do: %{}

  defp whole?(%{epoch: _, lifecycle: _, changed_at: _, changed_by: _}), do: true
  defp whole?(_), do: false

  defp changed_by(metadata) do
    case meta(metadata) do
      %{changed_by: node_name} when is_atom(node_name) -> node_name
      _ -> node()
    end
  end

  # A bound node is the definition of running, so a start needs no explicit
  # transition to clear a `:stopped` row. Writes that leave the row unbound keep
  # whatever lifecycle it already had.
  defp implied_lifecycle([_ | _], _previous), do: :running
  defp implied_lifecycle(_empty, %{lifecycle: lifecycle}), do: lifecycle
  defp implied_lifecycle(_empty, _previous), do: :running

  defp author(previous, lifecycle) do
    authored = %{
      epoch: (previous[:epoch] || 0) + 1,
      lifecycle: lifecycle,
      changed_at: Entry.now_ms(),
      changed_by: node()
    }

    case lifecycle do
      # Re-stamping an already-stopped row keeps the original deadline rather
      # than pushing it out.
      :stopped -> Map.put(authored, :stopped_at, previous[:stopped_at] || Entry.now_ms())
      _ -> authored
    end
  end
end
