defmodule ProcessHub.Service.Batch do
  @moduledoc """
  The items queued behind one flush — the core of a group commit.

  `add/3` queues an item and, when the batch was empty, sends `flush_msg` to
  the current process once. That message lands behind every request already
  in the mailbox, so everything that arrives before it joins the same batch;
  `take/1` hands the items back in arrival order and empties the batch. The
  owner decides what one flush does — one durable sync, one manifest write —
  and answers every item after it.
  """

  defstruct items: [], open?: false

  @type t :: %__MODULE__{items: [term()], open?: boolean()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec add(t(), term(), term()) :: t()
  def add(%__MODULE__{open?: false}, flush_msg, item) do
    send(self(), flush_msg)
    %__MODULE__{items: [item], open?: true}
  end

  def add(%__MODULE__{items: items} = batch, _flush_msg, item) do
    %{batch | items: [item | items]}
  end

  @spec take(t()) :: {[term()], t()}
  def take(%__MODULE__{items: items}), do: {Enum.reverse(items), new()}
end
