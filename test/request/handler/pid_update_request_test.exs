defmodule Test.Request.Handler.PidUpdateRequestTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Request.Handler.PidUpdateRequest
  alias ProcessHub.Request.CrossNodeRequest
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook

  setup_all do
    Test.Helper.SetupHelper.setup_base(%{}, :pid_update_req_test)
  end

  setup %{hub_id: hub_id} = context do
    on_exit(:clear, fn -> ProcessRegistry.clear_all(hub_id) end)
    context
  end

  describe "new/3" do
    test "creates struct with child_id, node, pid" do
      pid = self()
      req = PidUpdateRequest.new(:child1, :some_node, pid)

      assert %PidUpdateRequest{} = req
      assert req.child_id == :child1
      assert req.node == :some_node
      assert req.pid == pid
    end
  end

  describe "handle/2" do
    test "updates existing child PID in registry", %{hub_id: hub_id, hub: hub} do
      hook = %HookManager{
        id: :pid_update_hook_test,
        m: :erlang,
        f: :send,
        a: [self(), :pid_updated]
      }

      HookManager.register_handler(hub.storage.hook, Hook.child_pid_updated(), hook)

      # Pre-insert a child
      child_spec = %{id: :update_child, start: {:mod, :fun, []}}
      child_nodes = [{:node1, :old_pid}]
      ProcessRegistry.insert(hub_id, child_spec, child_nodes, metadata: %{some: "meta"})

      # Create and handle the pid update request
      request = PidUpdateRequest.new(:update_child, :node1, :new_pid)
      CrossNodeRequest.handle(request, hub)

      # Verify PID was updated in registry
      {cs, nodes, metadata} = ProcessRegistry.lookup(hub_id, :update_child, with_metadata: true)
      assert cs == child_spec
      assert Keyword.get(nodes, :node1) == :new_pid
      assert Test.Helper.Common.caller_meta(metadata) == %{some: "meta"}

      # Verify hook fired
      assert_receive :pid_updated
    end

    test "returns nil when child not in registry", %{hub: hub} do
      request = PidUpdateRequest.new(:nonexistent, :node1, :some_pid)
      result = CrossNodeRequest.handle(request, hub)

      assert result == nil
    end
  end
end
