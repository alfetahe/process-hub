defmodule Test.Request.Handler.PidsRegisterRequestTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Request.Handler.PidsRegisterRequest

  describe "new/1" do
    test "creates struct with children_data" do
      data = %{child1: {%{id: :child1}, [{node(), self()}], %{}}}
      req = PidsRegisterRequest.new(data)

      assert %PidsRegisterRequest{} = req
      assert req.children_data == data
    end

    test "works with empty map" do
      req = PidsRegisterRequest.new(%{})
      assert req.children_data == %{}
    end

    test "preserves complex children_data structure" do
      pid = self()

      data = %{
        :child1 => {%{id: :child1, start: {MyMod, :start_link, []}}, [{node(), pid}], %{meta: 1}},
        :child2 => {%{id: :child2, start: {MyMod, :start_link, []}}, [{:other@host, pid}], %{}}
      }

      req = PidsRegisterRequest.new(data)
      assert map_size(req.children_data) == 2
    end
  end
end
