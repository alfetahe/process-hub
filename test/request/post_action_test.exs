defmodule Test.Request.PostActionTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Request.PostAction

  describe "new/3" do
    test "creates struct with module, function, and args" do
      pa = PostAction.new(Kernel, :send, [:extra_arg])
      assert pa.m == Kernel
      assert pa.f == :send
      assert pa.a == [:extra_arg]
    end
  end

  describe "new/2" do
    test "defaults args to empty list" do
      pa = PostAction.new(Kernel, :send)
      assert pa.m == Kernel
      assert pa.f == :send
      assert pa.a == []
    end
  end

  describe "MFA application" do
    test "PostAction can be used with apply/3" do
      pa = PostAction.new(Kernel, :+, [])
      result = apply(pa.m, pa.f, [1, 2])
      assert result == 3
    end

    test "PostAction args are appended to apply args" do
      pa = PostAction.new(Enum, :sum, [])
      result = apply(pa.m, pa.f, [[1, 2, 3] | pa.a])
      assert result == 6
    end
  end
end
