defmodule ProcessHub.Constant.PriorityLevel do
  @moduledoc """
  Priority levels for the local event queue.
  """

  @doc """
  Priority level for the local event queue when it is locked.
  """
  @spec locked() :: 10
  def locked(), do: 10

  @doc """
  Priority level for the local event queue when it is unlocked.
  """
  @spec unlocked() :: 0
  def unlocked(), do: 0
end
