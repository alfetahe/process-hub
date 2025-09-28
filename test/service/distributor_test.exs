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

  test "asda" do
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

    Distributor.init_children(hub, [cs1, cs2],
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

  test "add children", %{hub: hub} = _context do
    child_spec = %{
      id: :dist_child_add,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_add}]}
    }

    child_spec2 = %{
      id: :dist_child_add2,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_add2}]}
    }

    Distributor.init_children(hub, [child_spec, child_spec2],
      awaitable: true,
      check_existing: false,
      init_cids: [:dist_child_add, :dist_child_add2],
      timeout: 5000
    )
    |> ProcessHub.Future.await()

    local_node = node()
    res = ProcessRegistry.dump(hub.hub_id) |> Keyword.new()

    assert length(res) === 2

    assert Enum.all?(res, fn {child_id, _} ->
             Enum.member?([:dist_child_add, :dist_child_add2], child_id)
           end)

    assert Enum.all?(res, fn {_, {_, [{^local_node, pid}], _}} -> is_pid(pid) end)
  end

  test "stop child", %{hub: hub} = _context do
    child_spec = %{
      id: :dist_child_stop,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_stop}]}
    }

    Distributor.init_children(hub, [child_spec],
      awaitable: true,
      check_existing: true,
      init_cids: [:dist_child_stop],
      timeout: 1000
    )
    |> ProcessHub.Future.await()

    Distributor.stop_children(hub, [child_spec.id],
      awaitable: true,
      check_existing: true,
      timeout: 1000
    )
    |> ProcessHub.Future.await()

    assert ProcessRegistry.dump(hub.hub_id) === %{}
  end

  test "children redist init", %{hub: hub} = _context do
    child_spec = %{
      id: :dist_child_stop,
      start: {Test.Helper.TestServer, :start_link, [%{name: :dist_child_stop}]}
    }

    metadata = %{tag: "test_tag"}

    assert Distributor.children_redist_init(hub, node(), [{child_spec, metadata}]) ===
             {:ok, :redistribution_initiated}
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

  test "default_init_opts with partial options" do
    input_opts = [
      awaitable: true,
      init_cids: [:child1, :child2]
    ]

    result = Distributor.default_init_opts(input_opts)

    # Provided values should be preserved
    assert Keyword.get(result, :awaitable) === true
    assert Keyword.get(result, :init_cids) === [:child1, :child2]

    # Missing values should get defaults
    assert Keyword.get(result, :timeout) === 10_000
    assert Keyword.get(result, :async_wait) === false
    assert Keyword.get(result, :check_existing) === true
    assert Keyword.get(result, :on_failure) === :continue
    assert Keyword.get(result, :metadata) === %{}
    assert Keyword.get(result, :await_timeout) === 60_000
  end

  test "default_init_opts with all options provided" do
    input_opts = [
      timeout: 15_000,
      awaitable: true,
      async_wait: true,
      check_existing: false,
      on_failure: :rollback,
      metadata: %{tag: "test"},
      await_timeout: 30_000,
      init_cids: [:test_child]
    ]

    result = Distributor.default_init_opts(input_opts)

    # All values should be preserved (no defaults applied)
    assert Keyword.get(result, :timeout) === 15_000
    assert Keyword.get(result, :awaitable) === true
    assert Keyword.get(result, :async_wait) === true
    assert Keyword.get(result, :check_existing) === false
    assert Keyword.get(result, :on_failure) === :rollback
    assert Keyword.get(result, :metadata) === %{tag: "test"}
    assert Keyword.get(result, :await_timeout) === 30_000
    assert Keyword.get(result, :init_cids) === [:test_child]
  end

  test "default_init_opts handles edge cases" do
    # Test with nil values (should be preserved)
    input_opts = [metadata: nil, init_cids: nil]
    result = Distributor.default_init_opts(input_opts)

    assert Keyword.get(result, :metadata) === nil
    assert Keyword.get(result, :init_cids) === nil
    assert Keyword.get(result, :timeout) === 10_000  # Default applied

    # Test with zero/false values (should be preserved)
    input_opts2 = [timeout: 0, awaitable: false]
    result2 = Distributor.default_init_opts(input_opts2)

    assert Keyword.get(result2, :timeout) === 0
    assert Keyword.get(result2, :awaitable) === false
    assert Keyword.get(result2, :check_existing) === true  # Default applied
  end

  test "default_init_opts order preservation" do
    input_opts = [
      awaitable: true,
      timeout: 5_000,
      custom_option: "test"
    ]

    result = Distributor.default_init_opts(input_opts)

    # Original options should appear first in the result
    assert Keyword.take(result, [:awaitable, :timeout, :custom_option]) === input_opts
  end
end
