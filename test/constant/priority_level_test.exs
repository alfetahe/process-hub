defmodule Test.Constant.PriorityLevelTest do
  use ExUnit.Case

  test "high" do
    assert ProcessHub.Constant.PriorityLevel.high() === 100
  end

  test "medium" do
    assert ProcessHub.Constant.PriorityLevel.medium() === 50
  end

  test "low" do
    assert ProcessHub.Constant.PriorityLevel.low() === 0
  end
end
