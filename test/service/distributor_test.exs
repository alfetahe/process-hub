defmodule Test.Service.DistributorTest do
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Distributor
  alias ProcessHub

  use ProcessHub.Constant.Event
  use ExUnit.Case

  setup _context do
    Test.Helper.SetupHelper.setup_base(%{}, :distributor_test)
  end

  test "local supevisor children", %{hub: hub} = _context do
    assert Distributor.which_children_local(hub, []) === {:"process_hub@127.0.0.1", []}

    {:ok, _pid} =
      ProcessHub.DistributedSupervisor.start_child(
        hub.procs.dist_sup,
        %{
          id: :test_child,
          start: {Test.Helper.TestServer, :start_link, [%{name: :test_local_sup_child}]}
        }
      )

    {:ok, _pid} =
      ProcessHub.DistributedSupervisor.start_child(
        hub.procs.dist_sup,
        %{
          id: :test_child2,
          start: {Test.Helper.TestServer, :start_link, [%{name: :test_local_sup_child2}]}
        }
      )

    {:"process_hub@127.0.0.1", children} = Distributor.which_children_local(hub, [])

    assert length(children) === 2
    assert Enum.all?(children, fn {_, pid, _, _} -> is_pid(pid) end)

    assert Enum.all?(children, fn {child_id, _, _, _} ->
             Enum.member?([:test_child, :test_child2], child_id)
           end)
  end

  test "global supevisor children", %{hub: hub} = _context do
    assert Distributor.which_children_global(hub, []) === [{:"process_hub@127.0.0.1", []}]

    {:ok, _pid} =
      ProcessHub.DistributedSupervisor.start_child(
        hub.procs.dist_sup,
        %{
          id: :test_child_global,
          start: {Test.Helper.TestServer, :start_link, [%{name: :test_global_sup_child}]}
        }
      )

    {:ok, _pid} =
      ProcessHub.DistributedSupervisor.start_child(
        hub.procs.dist_sup,
        %{
          id: :test_child2_global,
          start: {Test.Helper.TestServer, :start_link, [%{name: :test_global_sup_child2}]}
        }
      )

    [{:"process_hub@127.0.0.1", children}] = Distributor.which_children_global(hub, [])

    assert length(children) === 2
    assert Enum.all?(children, fn {_, pid, _, _} -> is_pid(pid) end)

    assert Enum.all?(children, fn {child_id, _, _, _} ->
             Enum.member?([:test_child_global, :test_child2_global], child_id)
           end)
  end

  test "terminate children", %{hub: hub} = _context do
    misc_storage = hub.storage.misc

    cs1 = %{
      id: :dist_child_add,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_add}]}
    }

    cs2 = %{
      id: :dist_child_add2,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_add2}]}
    }

    # We need to call process hub start children directly
    # to store the request in the coordinator.
    ProcessHub.start_children(hub.hub_id, [cs1, cs2],
      awaitable: true,
      check_existing: true,
      init_cids: [:dist_child_add, :dist_child_add2],
      timeout: 5000
    )
    |> ProcessHub.Future.await()

    sync_strategy = ProcessHub.Service.Storage.get(misc_storage, :synchronization_strategy)

    Distributor.children_terminate(hub, [cs1.id, cs2.id], sync_strategy)

    assert Supervisor.which_children(hub.procs.dist_sup) === []
  end

  test "add children", %{hub_id: hub_id, hub: hub} = _context do
    child_spec = %{
      id: :dist_child_add,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_add}]}
    }

    child_spec2 = %{
      id: :dist_child_add2,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_add2}]}
    }

    # Use ProcessHub.start_children which goes through the coordinator
    ProcessHub.start_children(hub_id, [child_spec, child_spec2], awaitable: true, timeout: 5000)
    |> ProcessHub.Future.await()

    local_node = node()
    res = ProcessRegistry.dump(hub.hub_id) |> Keyword.new()

    assert length(res) === 2

    assert Enum.all?(res, fn {child_id, _} ->
             Enum.member?([:dist_child_add, :dist_child_add2], child_id)
           end)

    assert Enum.all?(res, fn {_, {_, [{^local_node, pid}], _}} -> is_pid(pid) end)
  end

  test "stop child", %{hub_id: hub_id, hub: hub} = _context do
    child_spec = %{
      id: :dist_child_stop,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_stop}]}
    }

    # Use ProcessHub.start_children which goes through the coordinator
    ProcessHub.start_children(hub_id, [child_spec], awaitable: true, timeout: 1000)
    |> ProcessHub.Future.await()

    # Use ProcessHub.stop_children which goes through the coordinator
    {:ok, stop_future} =
      ProcessHub.stop_children(hub_id, [child_spec.id],
        awaitable: true,
        timeout: 1000
      )

    ProcessHub.Future.await(stop_future)

    assert ProcessRegistry.dump(hub.hub_id) === %{}
  end

  test "default_init_opts with empty options" do
    result = Distributor.default_init_opts([])

    assert Keyword.get(result, :timeout) === 10_000
    assert Keyword.get(result, :awaitable) === false
    assert Keyword.get(result, :async_wait) === false
    assert Keyword.get(result, :check_existing) === true
    assert Keyword.get(result, :on_failure) === :continue
    assert Keyword.get(result, :metadata) === %{}
    assert Keyword.get(result, :await_timeout) === 60_000
    assert Keyword.get(result, :init_cids) === []
  end

  test "default_init_opts preserves existing values" do
    input_opts = [
      timeout: 5_000,
      awaitable: true,
      on_failure: :rollback,
      metadata: %{custom: "value"}
    ]

    result = Distributor.default_init_opts(input_opts)

    # Existing values should be preserved
    assert Keyword.get(result, :timeout) === 5_000
    assert Keyword.get(result, :awaitable) === true
    assert Keyword.get(result, :on_failure) === :rollback
    assert Keyword.get(result, :metadata) === %{custom: "value"}

    # Missing values should get defaults
    assert Keyword.get(result, :async_wait) === false
    assert Keyword.get(result, :check_existing) === true
    assert Keyword.get(result, :await_timeout) === 60_000
    assert Keyword.get(result, :init_cids) === []
  end

  describe "compose_start_operation/3" do
    test "returns error when child_specs is empty", %{hub: hub} do
      assert Distributor.compose_start_operation(hub, [], []) === {:error, :no_children}
    end

    test "starts children and returns operation", %{hub: hub} do
      child_spec = %{
        id: :compose_start_test,
        start: {Test.Helper.TestServer, :start_link, [%{name: :compose_start_test}]}
      }

      opts = Distributor.default_init_opts(timeout: 5000)
      result = Distributor.compose_start_operation(hub, [child_spec], opts)

      assert {:ok, %ProcessHub.Service.RequestManager{} = operation} = result
      assert operation.hub_id === hub.hub_id
      assert operation.handler === ProcessHub.Request.Handler.StartChildrenRequest
      assert is_list(operation.sub_requests)
      assert length(operation.sub_requests) >= 1
    end

    test "returns error for already started children", %{hub: hub} do
      child_spec = %{
        id: :compose_dup_test,
        start: {Test.Helper.TestServer, :start_link, [%{name: :compose_dup_test}]}
      }

      # Start the child via ProcessHub so it's fully registered before checking
      ProcessHub.start_children(hub.hub_id, [child_spec], awaitable: true, timeout: 5000)
      |> ProcessHub.Future.await()

      # Try to start the same child again with check_existing: true
      opts2 = Distributor.default_init_opts(timeout: 5000, check_existing: true)
      result = Distributor.compose_start_operation(hub, [child_spec], opts2)

      assert {:error, {:already_started, child_ids}} = result
      assert :compose_dup_test in child_ids
    end

    test "skips check_existing when option is false", %{hub: hub} do
      child_spec = %{
        id: :compose_nocheck_test,
        start: {Test.Helper.TestServer, :start_link, [%{name: :compose_nocheck_test}]}
      }

      opts = Distributor.default_init_opts(timeout: 5000, check_existing: false)
      result = Distributor.compose_start_operation(hub, [child_spec], opts)

      assert {:ok, %ProcessHub.Service.RequestManager{}} = result
    end
  end

  describe "compose_stop_operation/3" do
    test "returns error when child_ids is empty", %{hub: hub} do
      opts = Distributor.default_init_opts([])
      assert Distributor.compose_stop_operation(hub, [], opts) === {:error, :no_children}
    end

    test "handles stopping non-existent children", %{hub: hub} do
      opts = Distributor.default_init_opts(timeout: 5000)
      result = Distributor.compose_stop_operation(hub, [:nonexistent_child], opts)

      # Should still return {:ok, operation} for not_found children so awaitable works
      assert {:ok, %ProcessHub.Service.RequestManager{} = operation} = result
      assert operation.handler === ProcessHub.Request.Handler.StopChildrenRequest
    end

    test "stops existing children and returns operation", %{hub_id: hub_id, hub: hub} do
      child_spec = %{
        id: :compose_stop_test,
        start: {Test.Helper.TestServer, :start_link, [%{name: :compose_stop_test}]}
      }

      # Start the child first via ProcessHub
      ProcessHub.start_children(hub_id, [child_spec], awaitable: true, timeout: 5000)
      |> ProcessHub.Future.await()

      # Verify child exists
      assert ProcessRegistry.lookup(hub_id, :compose_stop_test) !== nil

      opts = Distributor.default_init_opts(timeout: 5000)
      result = Distributor.compose_stop_operation(hub, [:compose_stop_test], opts)

      assert {:ok, %ProcessHub.Service.RequestManager{} = operation} = result
      assert operation.handler === ProcessHub.Request.Handler.StopChildrenRequest
      assert is_list(operation.sub_requests)
      assert length(operation.sub_requests) >= 1
    end

    test "mixed existing and non-existing children", %{hub_id: hub_id, hub: hub} do
      child_spec = %{
        id: :compose_stop_mix,
        start: {Test.Helper.TestServer, :start_link, [%{name: :compose_stop_mix}]}
      }

      ProcessHub.start_children(hub_id, [child_spec], awaitable: true, timeout: 5000)
      |> ProcessHub.Future.await()

      opts = Distributor.default_init_opts(timeout: 5000)

      # Stop one existing and one non-existing child
      result = Distributor.compose_stop_operation(hub, [:compose_stop_mix, :nope], opts)

      assert {:ok, %ProcessHub.Service.RequestManager{} = operation} = result
      # The not_found_children should be tracked in opts
      assert operation.handler === ProcessHub.Request.Handler.StopChildrenRequest
    end
  end

  test "compose_stop_operation returns error when children have empty node_pids",
       %{hub: hub} do
    # Insert a child into the process registry with empty node_pids.
    # This means the child exists but is assigned to no nodes, so both
    # nodes_data and not_found will be [] after the reduce.
    child_spec = %{id: :empty_pids_child, start: {Agent, :start_link, [fn -> nil end]}}
    ProcessRegistry.insert(hub.hub_id, child_spec, [])

    opts = Distributor.default_init_opts([])

    assert {:error, :no_children} =
             Distributor.compose_stop_operation(hub, [:empty_pids_child], opts)
  end

  test "compose_start_operation returns error when distribution assigns no nodes",
       %{hub: hub} do
    # Replace the hash ring with an empty one so belongs_to returns no nodes,
    # causing dispatch_operation to receive empty nodes_data.
    empty_ring = ProcessHub.Service.Ring.create_ring([])
    ProcessHub.Service.Storage.insert(hub.storage.misc, :hash_ring, empty_ring)

    child_spec = %{
      id: :no_nodes_child,
      start: {Test.Helper.TestServer, :start_link, [%{name: :no_nodes_child}]}
    }

    opts = Distributor.default_init_opts(check_existing: false)
    assert {:error, :no_children} = Distributor.compose_start_operation(hub, [child_spec], opts)
  end

  describe "calculate_call_timeout/2" do
    test "calculates timeout based on child count with default formula" do
      # Formula: 5000ms + (1ms × child_count)
      assert Distributor.calculate_call_timeout(0, []) === 5000
      assert Distributor.calculate_call_timeout(100, []) === 5100
      assert Distributor.calculate_call_timeout(1000, []) === 6000
      assert Distributor.calculate_call_timeout(10_000, []) === 15_000
      assert Distributor.calculate_call_timeout(30_000, []) === 35_000
      assert Distributor.calculate_call_timeout(100_000, []) === 105_000
    end

    test "allows override with :call_timeout option" do
      # Explicit timeout should override the calculation
      assert Distributor.calculate_call_timeout(100, call_timeout: 60_000) === 60_000
      assert Distributor.calculate_call_timeout(30_000, call_timeout: 10_000) === 10_000
    end

    test "supports :infinity timeout" do
      assert Distributor.calculate_call_timeout(100, call_timeout: :infinity) === :infinity
      assert Distributor.calculate_call_timeout(100_000, call_timeout: :infinity) === :infinity
    end

    test "ignores other options and only uses :call_timeout" do
      opts = [awaitable: true, timeout: 5000, metadata: %{}, call_timeout: 20_000]
      assert Distributor.calculate_call_timeout(100, opts) === 20_000
    end

    test "uses calculated timeout when :call_timeout is nil" do
      opts = [awaitable: true, call_timeout: nil]
      # nil is treated same as not provided, so formula applies
      assert Distributor.calculate_call_timeout(1000, opts) === 6000
    end
  end
end
