defmodule Test.Request.Handler.PidsUnregisterRequestTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Request.Handler.PidsUnregisterRequest

  describe "new/1" do
    test "creates struct with removable_cid_nodes" do
      data = [{:child1, [node()]}, {:child2, [:other@host]}]
      req = PidsUnregisterRequest.new(data)

      assert %PidsUnregisterRequest{} = req
      assert req.removable_cid_nodes == data
    end

    test "works with empty list" do
      req = PidsUnregisterRequest.new([])
      assert req.removable_cid_nodes == []
    end

    test "preserves multiple node entries" do
      data = [{:child1, [node(), :n2@host, :n3@host]}]
      req = PidsUnregisterRequest.new(data)

      [{:child1, nodes}] = req.removable_cid_nodes
      assert length(nodes) == 3
    end
  end
end
