defmodule Test.Service.DistributorTest do
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Utility.Name

  use ProcessHub.Constant.Event
  use ExUnit.Case

  setup _context do
    Test.Helper.SetupHelper.setup_base(%{}, :distributor_test)
  end

  test "local supevisor children", %{hub_id: hub_id} = _context do
    assert Distributor.which_children_local(hub_id, []) === {:"process_hub@127.0.0.1", []}

    {:ok, _pid} =
      Name.distributed_supervisor(hub_id)
      |> ProcessHub.DistributedSupervisor.start_child(%{
        id: :test_child,
        start: {Test.Helper.TestServer, :start_link, [%{name: :test_local_sup_child}]}
      })

    {:ok, _pid} =
      Name.distributed_supervisor(hub_id)
      |> ProcessHub.DistributedSupervisor.start_child(%{
        id: :test_child2,
        start: {Test.Helper.TestServer, :start_link, [%{name: :test_local_sup_child2}]}
      })

    {:"process_hub@127.0.0.1", children} = Distributor.which_children_local(hub_id, [])

    assert length(children) === 2
    assert Enum.all?(children, fn {_, pid, _, _} -> is_pid(pid) end)

    assert Enum.all?(children, fn {child_id, _, _, _} ->
             Enum.member?([:test_child, :test_child2], child_id)
           end)
  end

  test "asda" do
  end

  test "global supevisor children", %{hub_id: hub_id} = _context do
    assert Distributor.which_children_global(hub_id, []) === [{:"process_hub@127.0.0.1", []}]

    {:ok, _pid} =
      Name.distributed_supervisor(hub_id)
      |> ProcessHub.DistributedSupervisor.start_child(%{
        id: :test_child_global,
        start: {Test.Helper.TestServer, :start_link, [%{name: :test_global_sup_child}]}
      })

    {:ok, _pid} =
      Name.distributed_supervisor(hub_id)
      |> ProcessHub.DistributedSupervisor.start_child(%{
        id: :test_child2_global,
        start: {Test.Helper.TestServer, :start_link, [%{name: :test_global_sup_child2}]}
      })

    [{:"process_hub@127.0.0.1", children}] = Distributor.which_children_global(hub_id, [])

    assert length(children) === 2
    assert Enum.all?(children, fn {_, pid, _, _} -> is_pid(pid) end)

    assert Enum.all?(children, fn {child_id, _, _, _} ->
             Enum.member?([:test_child_global, :test_child2_global], child_id)
           end)
  end

  test "terminate children", %{hub_id: hub_id} = _context do
    local_storage = Name.local_storage(hub_id)

    cs1 = %{
      id: :dist_child_add,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_add}]}
    }

    cs2 = %{
      id: :dist_child_add2,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_add2}]}
    }

    Distributor.init_children(hub_id, [cs1, cs2],
      async_wait: true,
      check_existing: true,
      timeout: 5000
    )
    |> ProcessHub.await()

    sync_strategy = ProcessHub.Service.Storage.get(local_storage, :synchronization_strategy)

    Distributor.children_terminate(hub_id, [cs1.id, cs2.id], sync_strategy)

    assert Supervisor.which_children(Name.distributed_supervisor(hub_id)) === []
  end

  test "add children", %{hub_id: hub_id} = _context do
    child_spec = %{
      id: :dist_child_add,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_add}]}
    }

    child_spec2 = %{
      id: :dist_child_add2,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_add2}]}
    }

    Distributor.init_children(hub_id, [child_spec, child_spec2],
      async_wait: true,
      check_existing: false,
      timeout: 5000
    )
    |> ProcessHub.await()

    local_node = node()
    res = ProcessRegistry.dump(hub_id) |> Keyword.new()

    assert length(res) === 2

    assert Enum.all?(res, fn {child_id, _} ->
             Enum.member?([:dist_child_add, :dist_child_add2], child_id)
           end)

    assert Enum.all?(res, fn {_, {_, [{^local_node, pid}], _}} -> is_pid(pid) end)
  end

  test "stop child", %{hub_id: hub_id} = _context do
    child_spec = %{
      id: :dist_child_stop,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_stop}]}
    }

    Distributor.init_children(hub_id, [child_spec],
      async_wait: true,
      check_existing: true,
      timeout: 1000
    )
    |> ProcessHub.await()

    Distributor.stop_children(hub_id, [child_spec.id],
      async_wait: true,
      check_existing: true,
      timeout: 1000
    )
    |> ProcessHub.await()

    assert ProcessRegistry.dump(hub_id) === %{}
  end

  test "children redist init", %{hub_id: hub_id} = _context do
    child_spec = %{
      id: :dist_child_stop,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_stop}]}
    }

    metadata = %{tag: "test_tag"}

    assert Distributor.children_redist_init(hub_id, node(), [{child_spec, metadata}]) ===
             {:ok, :redistribution_initiated}
  end
end
