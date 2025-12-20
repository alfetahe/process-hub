defmodule ProcessHub.Constant.PriorityLevel do
  @moduledoc """
  Priority levels for the local event queue.
  """

  @type priority_level :: 0 | 50 | 100

  @doc """
  The priority level for high priority events in the local event queue.
  """
  @spec high() :: priority_level()
  def high(), do: 100

  @doc """
  Priority level for medium priority events in the local event queue.
  @spec medium() :: priority_level()
  """
  @spec medium() :: priority_level()
  def medium(), do: 50

  @doc """
  Priority level for low priority events in the local event queue.
  """
  @spec low() :: priority_level()
  def low(), do: 0
end
