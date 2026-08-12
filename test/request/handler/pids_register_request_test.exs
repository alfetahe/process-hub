defmodule Test.Request.Handler.PidsRegisterRequestTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Request.Handler.PidsRegisterRequest
  alias ProcessHub.Request.CrossNodeRequest
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook

  setup_all do
    Test.Helper.SetupHelper.setup_base(%{}, :pids_register_req_test)
  end

  setup %{hub_id: hub_id} = context do
    on_exit(:clear, fn -> ProcessRegistry.clear_all(hub_id) end)
    context
  end

  describe "new/1" do
    test "creates struct with children_data" do
      data = %{child1: {%{id: :child1}, [{node(), self()}], %{}}}
      req = PidsRegisterRequest.new(data)

      assert %PidsRegisterRequest{} = req
      assert req.children_data == data
    end
  end

  describe "handle/2" do
    test "bulk inserts children into registry and fires hooks", %{hub_id: hub_id, hub: hub} do
      hook = %HookManager{
        id: :pids_register_hook_test,
        m: :erlang,
        f: :send,
        a: [self(), :pid_registered]
      }

      HookManager.register_handler(hub.storage.hook, Hook.child_registered(), hook)

      assert ProcessRegistry.dump(hub_id) == %{}

      children_data = %{
        :child1 => {%{id: :child1, start: {:m, :f, []}}, [{:node1, :pid1}], %{tag: "a"}},
        :child2 => {%{id: :child2, start: {:m, :f, []}}, [{:node2, :pid2}], %{tag: "b"}},
        :child3 => {%{id: :child3, start: {:m, :f, []}}, [{:node3, :pid3}], %{}}
      }

      request = PidsRegisterRequest.new(children_data)
      CrossNodeRequest.handle(request, hub)

      # Verify all 3 children are in the registry
      registry = ProcessRegistry.dump(hub_id)
      assert map_size(registry) == 3
      assert Test.Helper.Common.caller_rows(registry) == children_data

      # Verify hook fired for each child
      Enum.each(1..3, fn _ ->
        assert_receive :pid_registered
      end)
    end
  end
end
