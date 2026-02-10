defmodule Test.Request.Handler.PidUpdateRequestTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Request.Handler.PidUpdateRequest

  describe "new/3" do
    test "creates struct with child_id, node, pid" do
      pid = self()
      req = PidUpdateRequest.new(:child1, :some_node, pid)

      assert req.child_id == :child1
      assert req.node == :some_node
      assert req.pid == pid
    end

    test "returns PidUpdateRequest struct" do
      req = PidUpdateRequest.new(:c, :n, self())
      assert %PidUpdateRequest{} = req
    end
  end
end
