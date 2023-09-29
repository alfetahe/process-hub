defmodule Test.Constant.PriorityLevelTest do
  use ExUnit.Case

  test "locked" do
    assert ProcessHub.Constant.PriorityLevel.locked() === 10
  end

  test "unlocked" do
    assert ProcessHub.Constant.PriorityLevel.unlocked() === 0
  end
end
