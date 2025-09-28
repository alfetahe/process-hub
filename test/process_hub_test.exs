defmodule ProcessHubTest do
  use ExUnit.Case
  # doctest ProcessHub

  setup %{} do
    Test.Helper.SetupHelper.setup_base(%{}, :process_hub_main_test)
  end

  @tag :start_children
  test "start children", %{hub_id: hub_id} do
    assert ProcessHub.start_children(hub_id, [], []) === {:error, :no_children}

    [cs1, cs2, cs3, cs4, cs5, cs6, cs7] =
      ProcessHub.Utility.Bag.gen_child_specs(7, id_type: :atom)

    assert ProcessHub.start_children(hub_id, [cs1], awaitable: false) ===
             {:ok, :start_initiated}

    result3 =
      ProcessHub.start_children(hub_id, [cs3], awaitable: true)
      |> ProcessHub.Future.await()

    assert ProcessHub.StartResult.status(result3) === :ok
    assert length(ProcessHub.StartResult.cids(result3)) === 1
    assert List.first(ProcessHub.StartResult.cids(result3)) === :child3

    assert ProcessHub.start_children(hub_id, [cs3]) === {:error, {:already_started, [:child3]}}

    {:ok, future} = ProcessHub.start_children(hub_id, [cs2], awaitable: true, timeout: 1000)
    assert is_struct(future)
    result2 = ProcessHub.Future.await(future)
    assert ProcessHub.StartResult.status(result2) === :ok
    assert ProcessHub.StartResult.cids(result2) === [:child2]
    assert ProcessHub.StartResult.node(result2) === node()
    assert is_pid(ProcessHub.StartResult.pid(result2))

    result4 =
      ProcessHub.start_children(hub_id, [cs4], awaitable: true, timeout: 0)
      |> ProcessHub.Future.await()

    assert ProcessHub.StartResult.status(result4) === :error

    assert ProcessHub.StartResult.errors(result4) === [
             {:undefined, :"process_hub@127.0.0.1", :node_receive_timeout}
           ]

    assert ProcessHub.StartResult.cids(result4) === []

    result5 =
      ProcessHub.start_children(hub_id, [cs5, cs5], awaitable: true, timeout: 1000)
      |> ProcessHub.Future.await()

    assert ProcessHub.StartResult.status(result5) === :error
    assert length(ProcessHub.StartResult.cids(result5)) === 1
    assert ProcessHub.StartResult.cids(result5) === [:child5]
    errors = ProcessHub.StartResult.errors(result5)
    assert length(errors) > 0

    Enum.each(errors, fn {child_id, node, result} ->
      assert child_id === :child5
      assert node === node()
      assert is_tuple(result)
      assert elem(result, 0) === :already_started
      assert is_pid(elem(result, 1))
    end)

    result67 =
      ProcessHub.start_children(hub_id, [cs6, cs7], awaitable: true, timeout: 1000)
      |> ProcessHub.Future.await()

    assert ProcessHub.StartResult.status(result67) === :ok
    child_ids = ProcessHub.StartResult.cids(result67)
    assert :child6 in child_ids
    assert :child7 in child_ids
    assert length(child_ids) === 2

    nodes = ProcessHub.StartResult.nodes(result67)
    assert node() in nodes

    pids = ProcessHub.StartResult.pids(result67)
    assert length(pids) === 2
    Enum.each(pids, &assert(is_pid(&1)))
  end

  test "start children error results", %{hub_id: hub_id} do
    err_spec = %{
      id: :error_cid,
      start: {Test.Helper.NonExisting, :start_link, [nil]}
    }

    result1 =
      ProcessHub.start_child(hub_id, err_spec,
        awaitable: true,
        disable_logging: true
      )
      |> ProcessHub.Future.await()

    err_spec2 = Map.put(err_spec, :id, :error_cid2)
    err_spec3 = Map.put(err_spec, :id, :error_cid3)

    result2 =
      ProcessHub.start_children(hub_id, [err_spec2, err_spec3],
        awaitable: true,
        disable_logging: true
      )
      |> ProcessHub.Future.await()

    assert ProcessHub.StartResult.status(result1) === :error
    assert ProcessHub.StartResult.cids(result1) === []
    [failure] = ProcessHub.StartResult.errors(result1)
    assert tuple_size(failure) === 3
    assert elem(failure, 0) === :error_cid
    assert elem(failure, 1) === node()
    assert elem(failure, 2) |> elem(0) |> elem(0) === :EXIT

    assert ProcessHub.StartResult.status(result2) === :error
    assert ProcessHub.StartResult.cids(result2) === []
    failures = ProcessHub.StartResult.errors(result2)
    assert is_list(failures)
    assert length(failures) === 2
  end

  @tag :start_child
  test "start child", %{hub_id: hub_id} do
    [cs1, cs2, cs3, cs4, cs5] = ProcessHub.Utility.Bag.gen_child_specs(5)

    assert ProcessHub.start_child(hub_id, cs1, awaitable: false) ===
             {:ok, :start_initiated}

    {:ok, future} = ProcessHub.start_child(hub_id, cs2, awaitable: true, timeout: 1000)
    assert is_struct(future)
    result2 = ProcessHub.Future.await(future)
    assert ProcessHub.StartResult.status(result2) === :ok
    assert ProcessHub.StartResult.cids(result2) === ["child2"]
    assert ProcessHub.StartResult.node(result2) === node()
    assert is_pid(ProcessHub.StartResult.pid(result2))

    result3 =
      ProcessHub.start_child(hub_id, cs3, awaitable: true)
      |> ProcessHub.Future.await()

    assert ProcessHub.StartResult.status(result3) === :ok
    assert ProcessHub.StartResult.cids(result3) === ["child3"]

    assert ProcessHub.start_child(hub_id, cs3) === {:error, {:already_started, ["child3"]}}

    result2_dup =
      ProcessHub.start_child(hub_id, cs2, awaitable: true, check_existing: false, timeout: 1000)
      |> ProcessHub.Future.await()

    assert ProcessHub.StartResult.status(result2_dup) === :error
    assert ProcessHub.StartResult.cids(result2_dup) === []
    [{"child2", _node, {:already_started, _pid}}] = ProcessHub.StartResult.errors(result2_dup)

    result4 =
      ProcessHub.start_child(hub_id, cs4, awaitable: true, timeout: 0)
      |> ProcessHub.Future.await()

    assert ProcessHub.StartResult.status(result4) === :error
    assert ProcessHub.StartResult.cids(result4) === []

    assert ProcessHub.StartResult.errors(result4) === [
             {:undefined, :"process_hub@127.0.0.1", :node_receive_timeout}
           ]

    ProcessHub.Service.Dispatcher.reply_respondents(
      [self()],
      :child_start_resp,
      "child5",
      {:ok, :nopid},
      node()
    )

    result5 =
      ProcessHub.start_child(hub_id, cs5,
        awaitable: true,
        timeout: 10
      )
      |> ProcessHub.Future.await()

    assert ProcessHub.StartResult.status(result5) === :ok
    assert ProcessHub.StartResult.cids(result5) === ["child5"]
    assert ProcessHub.StartResult.node(result5) === node()
    assert is_pid(ProcessHub.StartResult.pid(result5))
  end

  test "start children with rollback", %{hub_id: hub_id} = _context do
    working_spec = ProcessHub.Utility.Bag.gen_child_specs(1) |> List.first()

    error_spec = %{
      id: :error_cid,
      start: {Test.Helper.TestServer, :start_link_err, [%{hub_id: hub_id}]}
    }

    opts = [on_failure: :rollback, awaitable: true, disable_logging: true]

    rollback_result =
      ProcessHub.start_children(hub_id, [error_spec, working_spec], opts)
      |> ProcessHub.Future.await()

    assert ProcessHub.StartResult.status(rollback_result) === :error
    assert length(ProcessHub.StartResult.errors(rollback_result)) === 1
    assert length(ProcessHub.StartResult.cids(rollback_result)) === 1
    assert ProcessHub.process_list(hub_id, :global) === []

    # Test rollback by checking the formatted output
    {:error, {_errors, _started}, :rollback} = ProcessHub.StartResult.format(rollback_result)
  end

  test "stop children", %{hub_id: hub_id} = _context do
    child_specs = ProcessHub.Utility.Bag.gen_child_specs(3, id_type: :atom)

    ProcessHub.start_children(hub_id, child_specs, awaitable: true)
    |> ProcessHub.Future.await()

    assert ProcessHub.stop_children(hub_id, [:child1], awaitable: false) ===
             {:ok, :stop_initiated}

    assert ProcessHub.stop_children(hub_id, [:child2]) === {:ok, :stop_initiated}

    stop_none_result =
      ProcessHub.stop_children(hub_id, [:child_none], awaitable: true, timeout: 1000)
      |> ProcessHub.Future.await()

    assert ProcessHub.StopResult.status(stop_none_result) === :error
    assert ProcessHub.StopResult.cids(stop_none_result) === []

    assert ProcessHub.StopResult.errors(stop_none_result) === [
             {:undefined, node(), :node_receive_timeout}
           ]

    stop3_result =
      ProcessHub.stop_children(hub_id, [:child3], awaitable: true, timeout: 1000)
      |> ProcessHub.Future.await()

    assert ProcessHub.StopResult.status(stop3_result) === :ok
    assert ProcessHub.StopResult.cids(stop3_result) === [:child3]
    assert ProcessHub.StopResult.nodes(stop3_result) === [node()]
  end

  test "stop child", %{hub_id: hub_id} = _context do
    child_specs = ProcessHub.Utility.Bag.gen_child_specs(3, id_type: :atom)

    ProcessHub.start_children(hub_id, child_specs, awaitable: true)
    |> ProcessHub.Future.await()

    assert ProcessHub.stop_child(hub_id, :child1, awaitable: false) === {:ok, :stop_initiated}
    assert ProcessHub.stop_child(hub_id, :child2) === {:ok, :stop_initiated}

    stop_non_result =
      ProcessHub.stop_child(hub_id, :non_existing, awaitable: true, timeout: 100)
      |> ProcessHub.Future.await()

    assert ProcessHub.StopResult.status(stop_non_result) === :error
    assert ProcessHub.StopResult.cids(stop_non_result) === []

    assert ProcessHub.StopResult.errors(stop_non_result) === [
             {:undefined, node(), :node_receive_timeout}
           ]

    stop_child3_result =
      ProcessHub.stop_child(hub_id, :child3, awaitable: true, timeout: 100)
      |> ProcessHub.Future.await()

    assert ProcessHub.StopResult.status(stop_child3_result) === :ok
    assert ProcessHub.StopResult.cids(stop_child3_result) === [:child3]
    assert ProcessHub.StopResult.nodes(stop_child3_result) === [node()]
  end

  test "stop child with string ids", %{hub_id: hub_id} = _context do
    child_specs = ProcessHub.Utility.Bag.gen_child_specs(3, id_type: :string)

    ProcessHub.start_children(hub_id, child_specs, awaitable: true)
    |> ProcessHub.Future.await()

    assert ProcessHub.stop_child(hub_id, "child1", awaitable: false) === {:ok, :stop_initiated}
    assert ProcessHub.stop_child(hub_id, "child2") === {:ok, :stop_initiated}

    stop_str_non_result =
      ProcessHub.stop_child(hub_id, "non_existing", awaitable: true, timeout: 100)
      |> ProcessHub.Future.await()

    assert ProcessHub.StopResult.status(stop_str_non_result) === :error
    assert ProcessHub.StopResult.cids(stop_str_non_result) === []

    assert ProcessHub.StopResult.errors(stop_str_non_result) === [
             {:undefined, node(), :node_receive_timeout}
           ]

    stop_str_child3_result =
      ProcessHub.stop_child(hub_id, "child3", awaitable: true, timeout: 100)
      |> ProcessHub.Future.await()

    assert ProcessHub.StopResult.status(stop_str_child3_result) === :ok
    assert ProcessHub.StopResult.cids(stop_str_child3_result) === ["child3"]
    assert ProcessHub.StopResult.nodes(stop_str_child3_result) === [:"process_hub@127.0.0.1"]
  end

  test "which children", %{hub_id: hub_id} = _context do
    child_specs = ProcessHub.Utility.Bag.gen_child_specs(2, id_type: :atom)

    ProcessHub.start_children(hub_id, child_specs, awaitable: true)
    |> ProcessHub.Future.await()

    local_node = node()

    # Use apply to supress the deprecation warnings.

    res =
      {^local_node, [{child_id2, pid2, type2, module2}, {child_id1, pid1, type1, module1}]} =
      apply(ProcessHub, :which_children, [hub_id])

    assert child_id1 === :child1
    assert child_id2 === :child2
    assert is_pid(pid1)
    assert is_pid(pid2)
    assert type1 === :worker
    assert type2 === :worker
    assert module1 === [Test.Helper.TestServer]
    assert module2 === [Test.Helper.TestServer]

    # Use apply to supress the deprecation warnings.
    assert apply(ProcessHub, :which_children, [hub_id, [:local]]) === res
    assert apply(ProcessHub, :which_children, [hub_id, [:global]]) === [res]
  end

  test "is alive?", %{hub_id: hub_id} = _context do
    assert ProcessHub.is_alive?(hub_id) === true
    assert ProcessHub.is_alive?(:none) === false
  end

  test "await", %{hub_id: hub_id} = _context do
    [child_spec1, child_spec2] = ProcessHub.Utility.Bag.gen_child_specs(2)
    assert ProcessHub.Future.await(:wrong_input) === {:error, :invalid_argument}

    assert ProcessHub.StartResult.format(
             ProcessHub.start_child(hub_id, child_spec1)
             |> ProcessHub.Future.await()
           ) === {:error, :invalid_argument}

    await_result =
      ProcessHub.start_child(hub_id, child_spec2, awaitable: true)
      |> ProcessHub.Future.await()

    assert ProcessHub.StartResult.status(await_result) === :ok
    assert ProcessHub.StartResult.cids(await_result) === [child_spec2.id]
    pids = ProcessHub.StartResult.pids(await_result)
    assert is_list(pids)
  end

  test "child_spec" do
    assert ProcessHub.child_spec(%{hub_id: :my_hub}) === %{
             id: :my_hub,
             start: {ProcessHub.Initializer, :start_link, [%{hub_id: :my_hub}]},
             type: :supervisor
           }
  end

  test "nodes", %{hub_id: hub_id} = _context do
    assert ProcessHub.nodes(hub_id) === []
    assert ProcessHub.nodes(hub_id, [:include_local]) === [node()]
  end

  test "start link", %{hub: hub} do
    hub_conf = %ProcessHub{
      hub_id: :start_link_test
    }

    assert ProcessHub.start_link(:none) === {:error, :expected_hub_settings}
    {:ok, pid} = ProcessHub.start_link(hub_conf)

    assert is_pid(pid)

    Supervisor.stop(hub.procs.initializer)
  end

  test "stop", %{hub_id: hub_id} = _context do
    assert ProcessHub.stop(:none) === {:error, :not_alive}
    assert ProcessHub.stop(hub_id) === :ok
  end

  test "is locked?", %{hub_id: hub_id, hub: hub} = _context do
    assert ProcessHub.is_locked?(hub_id) === false
    ProcessHub.Service.State.lock_event_handler(hub)
    assert ProcessHub.is_locked?(hub_id) === true
  end

  test "is partitioned?", %{hub_id: hub_id, hub: hub} = _context do
    assert ProcessHub.is_partitioned?(hub_id) === false
    ProcessHub.Service.State.toggle_quorum_failure(hub)
    assert ProcessHub.is_partitioned?(hub_id) === true
  end

  test "child lookup", %{hub_id: hub_id} = _context do
    assert ProcessHub.child_lookup(hub_id, :none) === nil

    [child_spec] = ProcessHub.Utility.Bag.gen_child_specs(1)

    ProcessHub.start_child(hub_id, child_spec, awaitable: true)
    |> ProcessHub.Future.await()

    {cs, nodepids} = ProcessHub.child_lookup(hub_id, child_spec.id)

    assert cs === child_spec
    assert is_list(nodepids)
    assert length(nodepids) === 1
    assert Enum.at(nodepids, 0) |> elem(0) === node()
    assert Enum.at(nodepids, 0) |> elem(1) |> is_pid()
  end

  test "registry", %{hub_id: hub_id} = _context do
    assert ProcessHub.registry_dump(hub_id) === %{}

    [cs1, cs2] = ProcessHub.Utility.Bag.gen_child_specs(2)

    ProcessHub.start_children(hub_id, [cs1, cs2], awaitable: true)
    |> ProcessHub.Future.await()

    %{"child1" => {^cs1, nodepids1, _}, "child2" => {^cs2, nodepids2, _}} =
      ProcessHub.registry_dump(hub_id)

    assert is_list(nodepids1)
    assert length(nodepids1) === 1
    assert Enum.at(nodepids1, 0) |> elem(0) === node()
    assert Enum.at(nodepids1, 0) |> elem(1) |> is_pid()

    assert is_list(nodepids2)
    assert length(nodepids2) === 1
    assert Enum.at(nodepids2, 0) |> elem(0) === node()
    assert Enum.at(nodepids2, 0) |> elem(1) |> is_pid()
  end

  test "dump", %{hub_id: hub_id} = _context do
    metadata = %{tag: "dump_test_tag"}
    assert ProcessHub.registry_dump(hub_id) === %{}

    [cs1, cs2] = ProcessHub.Utility.Bag.gen_child_specs(2)

    ProcessHub.start_children(
      hub_id,
      [cs1, cs2],
      awaitable: true,
      metadata: metadata
    )
    |> ProcessHub.Future.await()

    %{"child1" => {^cs1, nodepids1, metadata1}, "child2" => {^cs2, nodepids2, metadata2}} =
      ProcessHub.registry_dump(hub_id)

    assert is_list(nodepids1)
    assert length(nodepids1) === 1
    assert Enum.at(nodepids1, 0) |> elem(0) === node()
    assert Enum.at(nodepids1, 0) |> elem(1) |> is_pid()
    assert metadata1 === metadata

    assert is_list(nodepids2)
    assert length(nodepids2) === 1
    assert Enum.at(nodepids2, 0) |> elem(0) === node()
    assert Enum.at(nodepids2, 0) |> elem(1) |> is_pid()
    assert metadata2 === metadata
  end

  test "get pids", %{hub_id: hub_id} = _context do
    [cs1, cs2] = ProcessHub.Utility.Bag.gen_child_specs(2, id_type: :atom)

    ProcessHub.start_children(hub_id, [cs1, cs2], awaitable: true)
    |> ProcessHub.Future.await()

    c1_pids = ProcessHub.get_pids(hub_id, :child1)
    c2_pids = ProcessHub.get_pids(hub_id, :child2)
    not_existing = ProcessHub.get_pids(hub_id, :child3)

    assert is_list(c1_pids) && length(c1_pids) === 1
    assert is_list(c2_pids) && length(c2_pids) === 1
    assert is_list(not_existing) && length(not_existing) === 0

    Enum.each([c1_pids, c2_pids], fn pids ->
      Enum.each(pids, fn pid ->
        assert is_pid(pid)
      end)
    end)
  end

  test "get pid", %{hub_id: hub_id} = _context do
    [cs1, cs2] = ProcessHub.Utility.Bag.gen_child_specs(2)

    ProcessHub.start_children(hub_id, [cs1, cs2], awaitable: true)
    |> ProcessHub.Future.await()

    c1_pid = ProcessHub.get_pid(hub_id, "child1")
    c2_pid = ProcessHub.get_pid(hub_id, "child2")
    not_existing = ProcessHub.get_pid(hub_id, "child3")

    assert is_pid(c1_pid)
    assert is_pid(c2_pid)
    assert not_existing === nil
  end

  test "register hook handlers", %{hub_id: hub_id} = _context do
    # Test registering single handler
    handler1 = %ProcessHub.Service.HookManager{
      id: :test_hook_1,
      m: :erlang,
      f: :send,
      a: [self(), :hook_test_1],
      p: 100
    }

    result1 =
      ProcessHub.register_hook_handlers(
        hub_id,
        ProcessHub.Constant.Hook.pre_cluster_join(),
        [handler1]
      )

    assert result1 === :ok

    # Test registering multiple handlers
    handler2 = %ProcessHub.Service.HookManager{
      id: :test_hook_2,
      m: :erlang,
      f: :send,
      a: [self(), :hook_test_2],
      p: 50
    }

    handler3 = %ProcessHub.Service.HookManager{
      id: :test_hook_3,
      m: :erlang,
      f: :send,
      a: [self(), :hook_test_3],
      p: 150
    }

    result2 =
      ProcessHub.register_hook_handlers(
        hub_id,
        ProcessHub.Constant.Hook.post_cluster_join(),
        [handler2, handler3]
      )

    assert result2 === :ok

    # Test registering duplicate handler (should fail)
    duplicate_result =
      ProcessHub.register_hook_handlers(
        hub_id,
        ProcessHub.Constant.Hook.pre_cluster_join(),
        [handler1]
      )

    assert duplicate_result === {:error, :failed_to_register_some_handlers}

    # Test registering multiple handlers with duplicates
    duplicate_multiple_result =
      ProcessHub.register_hook_handlers(
        hub_id,
        ProcessHub.Constant.Hook.post_cluster_join(),
        [handler2, handler3]
      )

    assert duplicate_multiple_result ===
             {:error, :failed_to_register_some_handlers}
  end

  test "cancel hook handlers", %{hub_id: hub_id} = _context do
    # First register some handlers
    handler1 = %ProcessHub.Service.HookManager{
      id: :cancel_test_hook_1,
      m: :erlang,
      f: :send,
      a: [self(), :cancel_hook_test_1],
      p: 100
    }

    handler2 = %ProcessHub.Service.HookManager{
      id: :cancel_test_hook_2,
      m: :erlang,
      f: :send,
      a: [self(), :cancel_hook_test_2],
      p: 50
    }

    handler3 = %ProcessHub.Service.HookManager{
      id: :cancel_test_hook_3,
      m: :erlang,
      f: :send,
      a: [self(), :cancel_hook_test_3],
      p: 150
    }

    ProcessHub.register_hook_handlers(
      hub_id,
      ProcessHub.Constant.Hook.registry_pid_inserted(),
      [handler1, handler2, handler3]
    )

    # Test canceling single handler
    result1 =
      ProcessHub.cancel_hook_handlers(
        hub_id,
        ProcessHub.Constant.Hook.registry_pid_inserted(),
        [:cancel_test_hook_1]
      )

    assert result1 === :ok

    # Test canceling multiple handlers
    result2 =
      ProcessHub.cancel_hook_handlers(
        hub_id,
        ProcessHub.Constant.Hook.registry_pid_inserted(),
        [:cancel_test_hook_2, :cancel_test_hook_3]
      )

    assert result2 === :ok

    # Test canceling non-existing handlers (should still return :ok)
    result3 =
      ProcessHub.cancel_hook_handlers(
        hub_id,
        ProcessHub.Constant.Hook.registry_pid_inserted(),
        [:non_existing_handler]
      )

    assert result3 === :ok

    # Test canceling from empty hook key (should still return :ok)
    result4 =
      ProcessHub.cancel_hook_handlers(
        hub_id,
        ProcessHub.Constant.Hook.registry_pid_removed(),
        [:some_handler]
      )

    assert result4 === :ok
  end

  test "hook handlers integration", %{hub_id: hub_id} = _context do
    # Test full cycle: register, use, cancel
    test_pid = self()

    handler = %ProcessHub.Service.HookManager{
      id: :integration_test_hook,
      m: :erlang,
      f: :send,
      a: [test_pid, :integration_hook_fired],
      p: 100
    }

    # Register handler
    :ok =
      ProcessHub.register_hook_handlers(
        hub_id,
        ProcessHub.Constant.Hook.registry_pid_inserted(),
        [handler]
      )

    # Trigger the hook by starting a child (which registers a PID)
    [child_spec] = ProcessHub.Utility.Bag.gen_child_specs(1)

    ProcessHub.start_child(hub_id, child_spec, awaitable: true)
    |> ProcessHub.Future.await()

    # Verify the hook was called
    assert_receive :integration_hook_fired, 1000

    # Cancel the handler
    :ok =
      ProcessHub.cancel_hook_handlers(
        hub_id,
        ProcessHub.Constant.Hook.registry_pid_inserted(),
        [:integration_test_hook]
      )

    # Start another child to verify hook is no longer active
    [child_spec2] = ProcessHub.Utility.Bag.gen_child_specs(1, id_type: :atom)

    ProcessHub.start_child(hub_id, child_spec2, awaitable: true)
    |> ProcessHub.Future.await()

    # Verify the hook was NOT called this time
    refute_receive :integration_hook_fired, 100
  end
end
