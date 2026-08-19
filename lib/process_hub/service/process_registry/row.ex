defmodule ProcessHub.Service.ProcessRegistry.Row do
  @moduledoc """
  The registry row's ProcessHub-owned bookkeeping, stored under the reserved
  metadata key `:__process_hub__`.

  A registry row is `{child_spec, node_pids, metadata}`. `child_spec` and
  `node_pids` are the caller's and the cluster's; `metadata` is the caller's
  except for this one reserved key, which is the hub's:

      %{
        epoch: pos_integer(),          # per-child counter, never a wall clock
        changed_at: integer(),         # diagnostics only
        changed_by: node(),
        durable: true                  # only for children started durable: true
      }

  This module is the algebra over that key: who wins a merge, what an authored
  write stamps. It is pure — reads and writes belong to
  `ProcessHub.Service.ProcessRegistry`, which owns the table.

  > #### Experimental {: .warning}
  >
  > The `durable` flag is part of the experimental declared-children feature and
  > may change in future releases. The epoch and merge ordering apply to every
  > hub.
  """

  alias ProcessHub.Service.Storage.Entry

  @reserved_key :__process_hub__

  @typedoc "The reserved bookkeeping map carried by every row's metadata."
  @type t() :: %{
          :epoch => pos_integer(),
          :changed_at => integer(),
          :changed_by => node(),
          optional(:durable) => true
        }

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

  @doc "Returns whether a row belongs to a child declared with `durable: true`."
  @spec durable?(map() | nil) :: boolean()
  def durable?(metadata) do
    case meta(metadata) do
      %{durable: true} -> true
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
  local node stamps itself. `opts[:durable]` marks the row's child as declared;
  once set, the flag survives every subsequent authored write.

  `forged?` reports on *shape*, not equality. Passing the stored bookkeeping
  straight back is the norm — every read-modify-write does it, and a concurrent
  write in between makes the value legitimately stale — so only a value that is
  not a whole bookkeeping map could have been hand-written. Either way the
  supplied value is ignored.
  """
  @spec stamp(map(), t() | nil, keyword()) :: {map(), boolean()}
  def stamp(caller_metadata, previous, opts) do
    supplied = meta(caller_metadata)
    metadata = strip(caller_metadata)

    case {Keyword.get(opts, :adopt, false), supplied} do
      {true, %{} = adopted} ->
        {Map.put(metadata, @reserved_key, adopted), false}

      _ ->
        durable? = Keyword.get(opts, :durable, false) or match?(%{durable: true}, previous)

        {Map.put(metadata, @reserved_key, author(previous, durable?)),
         not is_nil(supplied) and not whole?(supplied)}
    end
  end

  defp strip(metadata) when is_map(metadata), do: Map.delete(metadata, @reserved_key)
  defp strip(_), do: %{}

  defp whole?(%{epoch: _, changed_at: _, changed_by: _}), do: true
  defp whole?(_), do: false

  defp changed_by(metadata) do
    case meta(metadata) do
      %{changed_by: node_name} when is_atom(node_name) -> node_name
      _ -> node()
    end
  end

  defp author(previous, durable?) do
    authored = %{
      epoch: (previous[:epoch] || 0) + 1,
      changed_at: Entry.now_ms(),
      changed_by: node()
    }

    if durable?, do: Map.put(authored, :durable, true), else: authored
  end
end
