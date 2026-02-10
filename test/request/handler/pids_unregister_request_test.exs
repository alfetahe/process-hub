defmodule Test.Request.Handler.PidsUnregisterRequestTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Request.Handler.PidsUnregisterRequest
  alias ProcessHub.Request.CrossNodeRequest
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook

  setup_all do
    Test.Helper.SetupHelper.setup_base(%{}, :pids_unregister_req_test)
  end

  setup %{hub_id: hub_id} = context do
    on_exit(:clear, fn -> ProcessRegistry.clear_all(hub_id) end)
    context
  end

  describe "new/1" do
    test "creates struct with removable_cid_nodes" do
      data = [{:child1, [node()]}, {:child2, [:other@host]}]
      req = PidsUnregisterRequest.new(data)

      assert %PidsUnregisterRequest{} = req
      assert req.removable_cid_nodes == data
    end
  end

  describe "handle/2" do
    test "bulk deletes children from registry and fires hooks", %{hub_id: hub_id, hub: hub} do
      hook = %HookManager{
        id: :pids_unregister_hook_test,
        m: :erlang,
        f: :send,
        a: [self(), :pid_unregistered]
      }

      HookManager.register_handler(hub.storage.hook, Hook.registry_pid_removed(), hook)

      # Pre-insert 3 children
      insert_data = %{
        :child1 => {%{id: :child1, start: {:m, :f, []}}, [{:node1, :pid1}, {:node2, :pid2}], %{}},
        :child2 => {%{id: :child2, start: {:m, :f, []}}, [{:node3, :pid3}], %{}},
        :child3 => {%{id: :child3, start: {:m, :f, []}}, [{:node4, :pid4}, {:node5, :pid5}], %{}}
      }

      ProcessRegistry.bulk_insert(hub_id, insert_data)
      assert map_size(ProcessRegistry.dump(hub_id)) == 3

      # Build delete data: {child_id, [nodes_to_remove]}
      del_data =
        Enum.map(insert_data, fn {child_id, {_, child_nodes, _}} ->
          {child_id, Enum.map(child_nodes, fn {node, _pid} -> node end)}
        end)

      request = PidsUnregisterRequest.new(del_data)
      CrossNodeRequest.handle(request, hub)

      # Verify registry is empty
      assert ProcessRegistry.dump(hub_id) == %{}

      # Verify hook fired for each child
      Enum.each(1..3, fn _ ->
        assert_receive :pid_unregistered
      end)
    end
  end
end
