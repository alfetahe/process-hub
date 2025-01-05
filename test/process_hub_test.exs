defmodule ProcessHubTest do
  use ExUnit.Case
  # doctest ProcessHub

  setup %{} do
    Test.Helper.SetupHelper.setup_base(%{}, :process_hub_main_test)
  end

  test "start children", %{hub_id: hub_id} do
    assert ProcessHub.start_children(hub_id, [], []) === {:error, :no_children}

    [cs1, cs2, cs3, cs4, cs5, cs6, cs7] =
      ProcessHub.Utility.Bag.gen_child_specs(7, id_type: :atom)

    assert ProcessHub.start_children(hub_id, [cs1], async_wait: false) ===
             {:ok, :start_initiated}

    {:ok, _} = ProcessHub.start_children(hub_id, [cs3], async_wait: true) |> ProcessHub.await()
    assert ProcessHub.start_children(hub_id, [cs3]) === {:error, {:already_started, [:child3]}}

    receiver = ProcessHub.start_children(hub_id, [cs2], async_wait: true, timeout: 1000)
    assert is_tuple(receiver)
    {:ok, children} = ProcessHub.await(receiver)
    assert is_list(children)
    assert length(children) === 1
    assert List.first(children) |> elem(0) === :child2
    [{child_id, pid}] = List.first(children) |> elem(1)
    assert child_id === node()
    assert is_pid(pid)

    assert ProcessHub.start_children(hub_id, [cs4], async_wait: true, timeout: 0)
           |> ProcessHub.await() ===
             {:error, {[node_receive_timeout: node()], []}}

    {status, results} =
      ProcessHub.start_children(hub_id, [cs5, cs5], async_wait: true, timeout: 1000)
      |> ProcessHub.await()

    errors = elem(results, 0)
    success_results = elem(results, 1)

    assert status === :error
    assert length(success_results) === 1
    assert length(errors) > 0

    Enum.each(errors, fn {child_id, node, result} ->
      assert child_id === :child5
      assert node === node()
      assert is_tuple(result)
      assert elem(result, 0) === :already_started
      assert is_pid(elem(result, 1))
    end)

    {status, children} =
      ProcessHub.start_children(hub_id, [cs6, cs7], async_wait: true, timeout: 1000)
      |> ProcessHub.await()

    assert status === :ok

    Enum.each(children, fn {child_id, results} ->
      assert child_id === :child6 or child_id === :child7

      {node, result} = Enum.at(results, 0)
      assert node === node()
      assert is_pid(result)
    end)
  end

  test "start child", %{hub_id: hub_id} do
    [cs1, cs2, cs3, cs4, cs5] = ProcessHub.Utility.Bag.gen_child_specs(5)

    assert ProcessHub.start_child(hub_id, cs1, async_wait: false) ===
             {:ok, :start_initiated}

    receiver = ProcessHub.start_child(hub_id, cs2, async_wait: true, timeout: 1000)
    assert is_tuple(receiver)
    {:ok, child_response} = ProcessHub.await(receiver)
    assert is_tuple(child_response)
    assert elem(child_response, 0) === "child2"
    [{node, pid}] = elem(child_response, 1)
    assert node === node()
    assert is_pid(pid)

    {:ok, _} = ProcessHub.start_child(hub_id, cs3, async_wait: true) |> ProcessHub.await()
    assert ProcessHub.start_child(hub_id, cs3) === {:error, {:already_started, ["child3"]}}

    {:error, {[{"child2", _node, {:already_started, _pid}}], []}} =
      ProcessHub.start_child(hub_id, cs2, async_wait: true, check_existing: false, timeout: 1000)
      |> ProcessHub.await()

    assert ProcessHub.start_child(hub_id, cs4, async_wait: true, timeout: 0)
           |> ProcessHub.await() === {:error, {[node_receive_timeout: node()], []}}

    ProcessHub.Service.Dispatcher.reply_respondents(
      [self()],
      :child_start_resp,
      "child5",
      {:ok, :nopid},
      node()
    )

    res5 =
      ProcessHub.start_child(hub_id, cs5,
        async_wait: true,
        timeout: 10
      )

    res5 = ProcessHub.await(res5)

    assert is_tuple(res5)
    assert elem(res5, 0) === :ok
    assert elem(res5, 1) |> elem(0) === "child5"
    [{node, pid}] = elem(res5, 1) |> elem(1)
    assert node === node()
    assert is_pid(pid)
  end

  test "stop children", %{hub_id: hub_id} = _context do
    child_specs = ProcessHub.Utility.Bag.gen_child_specs(3, id_type: :atom)

    ProcessHub.start_children(hub_id, child_specs, async_wait: true) |> ProcessHub.await()

    assert ProcessHub.stop_children(hub_id, [:child1], async_wait: false) ===
             {:ok, :stop_initiated}

    assert ProcessHub.stop_children(hub_id, [:child2]) === {:ok, :stop_initiated}

    assert ProcessHub.stop_children(hub_id, [:child_none], async_wait: true, timeout: 1000)
           |> ProcessHub.await() ===
             {:error, {[{:child_none, node(), :not_found}], []}}

    assert ProcessHub.stop_children(hub_id, [:child3], async_wait: true, timeout: 1000)
           |> ProcessHub.await() === {:ok, [child3: [node()]]}
  end

  test "stop child", %{hub_id: hub_id} = _context do
    child_specs = ProcessHub.Utility.Bag.gen_child_specs(3, id_type: :atom)

    ProcessHub.start_children(hub_id, child_specs, async_wait: true) |> ProcessHub.await()

    assert ProcessHub.stop_child(hub_id, :child1, async_wait: false) === {:ok, :stop_initiated}
    assert ProcessHub.stop_child(hub_id, :child2) === {:ok, :stop_initiated}

    assert ProcessHub.stop_child(hub_id, :non_existing, async_wait: true, timeout: 100)
           |> ProcessHub.await() === {:error, {[{:non_existing, node(), :not_found}], []}}

    assert ProcessHub.stop_child(hub_id, :child3, async_wait: true, timeout: 100)
           |> ProcessHub.await() === {:ok, {:child3, [node()]}}
  end

  test "stop child with string ids", %{hub_id: hub_id} = _context do
    child_specs = ProcessHub.Utility.Bag.gen_child_specs(3, id_type: :string)

    ProcessHub.start_children(hub_id, child_specs, async_wait: true) |> ProcessHub.await()

    assert ProcessHub.stop_child(hub_id, "child1", async_wait: false) === {:ok, :stop_initiated}
    assert ProcessHub.stop_child(hub_id, "child2") === {:ok, :stop_initiated}

    assert ProcessHub.stop_child(hub_id, "non_existing", async_wait: true, timeout: 100)
           |> ProcessHub.await() === {:error, {[{"non_existing", node(), :not_found}], []}}

    assert ProcessHub.stop_child(hub_id, "child3", async_wait: true, timeout: 100)
           |> ProcessHub.await() === {:ok, {"child3", [node()]}}
  end

  test "which children", %{hub_id: hub_id} = _context do
    child_specs = ProcessHub.Utility.Bag.gen_child_specs(2, id_type: :atom)

    ProcessHub.start_children(hub_id, child_specs, async_wait: true) |> ProcessHub.await()

    local_node = node()

    res =
      {^local_node, [{child_id2, pid2, type2, module2}, {child_id1, pid1, type1, module1}]} =
      ProcessHub.which_children(hub_id)

    assert child_id1 === :child1
    assert child_id2 === :child2
    assert is_pid(pid1)
    assert is_pid(pid2)
    assert type1 === :worker
    assert type2 === :worker
    assert module1 === [Test.Helper.TestServer]
    assert module2 === [Test.Helper.TestServer]

    assert ProcessHub.which_children(hub_id, [:local]) === res
    assert ProcessHub.which_children(hub_id, [:global]) === [res]
  end

  test "is alive?", %{hub_id: hub_id} = _context do
    assert ProcessHub.is_alive?(hub_id) === true
    assert ProcessHub.is_alive?(:none) === false
  end

  test "await", %{hub_id: hub_id} = _context do
    [child_spec1, child_spec2] = ProcessHub.Utility.Bag.gen_child_specs(2)
    assert ProcessHub.await(fn -> :await_test end) === {:error, :invalid_collector_pid}

    assert ProcessHub.start_child(hub_id, child_spec1) |> ProcessHub.await() ===
             {:error, :invalid_collector_pid}

    {:ok, {child_id, pids}} =
      ProcessHub.start_child(hub_id, child_spec2, async_wait: true) |> ProcessHub.await()

    assert child_id === child_spec2.id
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

  test "start link" do
    hub = %ProcessHub{
      hub_id: :start_link_test
    }

    assert ProcessHub.start_link(:none) === {:error, :expected_hub_settings}
    {:ok, pid} = ProcessHub.start_link(hub)

    assert is_pid(pid)

    Supervisor.stop(ProcessHub.Utility.Name.initializer(hub.hub_id))
  end

  test "stop", %{hub_id: hub_id} = _context do
    assert ProcessHub.stop(:none) === {:error, :not_alive}
    assert ProcessHub.stop(hub_id) === :ok
  end

  test "is locked?", %{hub_id: hub_id} = _context do
    assert ProcessHub.is_locked?(hub_id) === false
    ProcessHub.Service.State.lock_event_handler(hub_id)
    assert ProcessHub.is_locked?(hub_id) === true
  end

  test "is partitioned?", %{hub_id: hub_id} = _context do
    assert ProcessHub.is_partitioned?(hub_id) === false
    ProcessHub.Service.State.toggle_quorum_failure(hub_id)
    assert ProcessHub.is_partitioned?(hub_id) === true
  end

  test "child lookup", %{hub_id: hub_id} = _context do
    assert ProcessHub.child_lookup(hub_id, :none) === nil

    [child_spec] = ProcessHub.Utility.Bag.gen_child_specs(1)
    ProcessHub.start_child(hub_id, child_spec, async_wait: true) |> ProcessHub.await()
    {cs, nodepids} = ProcessHub.child_lookup(hub_id, child_spec.id)

    assert cs === child_spec
    assert is_list(nodepids)
    assert length(nodepids) === 1
    assert Enum.at(nodepids, 0) |> elem(0) === node()
    assert Enum.at(nodepids, 0) |> elem(1) |> is_pid()
  end

  test "registry", %{hub_id: hub_id} = _context do
    assert ProcessHub.process_registry(hub_id) === %{}

    [cs1, cs2] = ProcessHub.Utility.Bag.gen_child_specs(2)
    ProcessHub.start_children(hub_id, [cs1, cs2], async_wait: true) |> ProcessHub.await()

    %{"child1" => {^cs1, nodepids1}, "child2" => {^cs2, nodepids2}} =
      ProcessHub.process_registry(hub_id)

    assert is_list(nodepids1)
    assert length(nodepids1) === 1
    assert Enum.at(nodepids1, 0) |> elem(0) === node()
    assert Enum.at(nodepids1, 0) |> elem(1) |> is_pid()

    assert is_list(nodepids2)
    assert length(nodepids2) === 1
    assert Enum.at(nodepids2, 0) |> elem(0) === node()
    assert Enum.at(nodepids2, 0) |> elem(1) |> is_pid()
  end

  test "get pids", %{hub_id: hub_id} = _context do
    [cs1, cs2] = ProcessHub.Utility.Bag.gen_child_specs(2, id_type: :atom)
    ProcessHub.start_children(hub_id, [cs1, cs2], async_wait: true) |> ProcessHub.await()

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
    ProcessHub.start_children(hub_id, [cs1, cs2], async_wait: true) |> ProcessHub.await()

    c1_pid = ProcessHub.get_pid(hub_id, "child1")
    c2_pid = ProcessHub.get_pid(hub_id, "child2")
    not_existing = ProcessHub.get_pid(hub_id, "child3")

    assert is_pid(c1_pid)
    assert is_pid(c2_pid)
    assert not_existing === nil
  end
end
