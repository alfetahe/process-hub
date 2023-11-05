defmodule ProcessHub.Constant.PriorityLevel do
  @moduledoc """
  Priority levels for the local event queue.
  """

  @type priority_level :: 0 | 10

  @doc """
  Priority level for the local event queue when it is locked.
  """
  @spec locked() :: priority_level()
  def locked(), do: 10

  @doc """
  Priority level for the local event queue when it is unlocked.
  """
  @spec unlocked() :: priority_level()
  def unlocked(), do: 0
end
