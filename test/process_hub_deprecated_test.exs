defmodule ProcessHubDeprecatedTest do
  use ExUnit.Case
  # doctest ProcessHub

  setup %{} do
    Test.Helper.SetupHelper.setup_base(%{}, :deprecated_process_hub_main_test)
  end

  @tag :deprecated_start_children
  test "start children", %{hub_id: hub_id} do
    assert ProcessHub.start_children(hub_id, [], []) === {:error, :no_children}

    [cs1, cs2, cs3, cs4, cs5, cs6, cs7] =
      ProcessHub.Utility.Bag.gen_child_specs(7, id_type: :atom)

    assert ProcessHub.start_children(hub_id, [cs1], async_wait: false) ===
             {:ok, :start_initiated}

    {:ok, _} = ProcessHub.start_children(hub_id, [cs3], async_wait: true) |> ProcessHub.await()
    assert ProcessHub.start_children(hub_id, [cs3]) === {:error, {:already_started, [:child3]}}

    {:ok, receiver} = ProcessHub.start_children(hub_id, [cs2], async_wait: true, timeout: 1000)
    assert is_struct(receiver)
    {:ok, children} = ProcessHub.await(receiver)
    assert is_list(children)
    assert length(children) === 1
    assert List.first(children) |> elem(0) === :child2
    [{child_id, pid}] = List.first(children) |> elem(1)
    assert child_id === node()
    assert is_pid(pid)

    assert ProcessHub.start_children(hub_id, [cs4], async_wait: true, timeout: 0)
           |> ProcessHub.await() ===
             {:error, {[{:undefined, node(), :node_receive_timeout}], []}}

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

  test "start children error results", %{hub_id: hub_id} do
    err_spec = %{
      id: :error_cid,
      start: {Test.Helper.NonExisting, :start_link, [nil]}
    }

    {status1, {failure, success}} =
      ProcessHub.start_child(hub_id, err_spec,
        async_wait: true,
        disable_logging: true
      )
      |> ProcessHub.await()

    err_spec2 = Map.put(err_spec, :id, :error_cid2)
    err_spec3 = Map.put(err_spec, :id, :error_cid3)

    {status2, {failures, success_results}} =
      ProcessHub.start_children(hub_id, [err_spec2, err_spec3],
        async_wait: true,
        disable_logging: true
      )
      |> ProcessHub.await()

    assert status1 === :error
    assert success === []
    assert tuple_size(failure) === 3
    assert elem(failure, 0) === :error_cid
    assert elem(failure, 1) === node()
    assert elem(failure, 2) |> elem(0) |> elem(0) === :EXIT

    assert status2 === :error
    assert success_results === []
    assert is_list(failures)
    assert length(failures) === 2
  end

  @tag :deprecated_start_child
  test "start child", %{hub_id: hub_id} do
    [cs1, cs2, cs3, cs4, cs5] = ProcessHub.Utility.Bag.gen_child_specs(5)

    assert ProcessHub.start_child(hub_id, cs1, async_wait: false) ===
             {:ok, :start_initiated}

    {:ok, receiver} = ProcessHub.start_child(hub_id, cs2, async_wait: true, timeout: 1000)
    assert is_struct(receiver)
    {:ok, child_response} = ProcessHub.await(receiver)
    assert is_tuple(child_response)
    assert elem(child_response, 0) === "child2"
    [{node, pid}] = elem(child_response, 1)
    assert node === node()
    assert is_pid(pid)

    {:ok, _} = ProcessHub.start_child(hub_id, cs3, async_wait: true) |> ProcessHub.await()
    assert ProcessHub.start_child(hub_id, cs3) === {:error, {:already_started, ["child3"]}}

    {:error, {{"child2", _node, {:already_started, _pid}}, []}} =
      ProcessHub.start_child(hub_id, cs2, async_wait: true, check_existing: false, timeout: 1000)
      |> ProcessHub.await()

    assert ProcessHub.start_child(hub_id, cs4, async_wait: true, timeout: 0)
           |> ProcessHub.await() ===
             {:error, {{:undefined, :"process_hub@127.0.0.1", :node_receive_timeout}, []}}

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
             {:error, {[{:undefined, node(), :node_receive_timeout}], []}}

    assert ProcessHub.stop_children(hub_id, [:child3], async_wait: true, timeout: 1000)
           |> ProcessHub.await() === {:ok, [child3: [node()]]}
  end

  test "stop child", %{hub_id: hub_id} = _context do
    child_specs = ProcessHub.Utility.Bag.gen_child_specs(3, id_type: :atom)

    ProcessHub.start_children(hub_id, child_specs, async_wait: true) |> ProcessHub.await()

    assert ProcessHub.stop_child(hub_id, :child1, async_wait: false) === {:ok, :stop_initiated}
    assert ProcessHub.stop_child(hub_id, :child2) === {:ok, :stop_initiated}

    assert ProcessHub.stop_child(hub_id, :non_existing, async_wait: true, timeout: 100)
           |> ProcessHub.await() === {:error, {{:undefined, node(), :node_receive_timeout}, []}}

    assert ProcessHub.stop_child(hub_id, :child3, async_wait: true, timeout: 100)
           |> ProcessHub.await() === {:ok, {:child3, [node()]}}
  end

  test "stop child with string ids", %{hub_id: hub_id} = _context do
    child_specs = ProcessHub.Utility.Bag.gen_child_specs(3, id_type: :string)

    ProcessHub.start_children(hub_id, child_specs, async_wait: true) |> ProcessHub.await()

    assert ProcessHub.stop_child(hub_id, "child1", async_wait: false) === {:ok, :stop_initiated}
    assert ProcessHub.stop_child(hub_id, "child2") === {:ok, :stop_initiated}

    assert ProcessHub.stop_child(hub_id, "non_existing", async_wait: true, timeout: 100)
           |> ProcessHub.await() === {:error, {{:undefined, node(), :node_receive_timeout}, []}}

    assert ProcessHub.stop_child(hub_id, "child3", async_wait: true, timeout: 100)
           |> ProcessHub.await() === {:ok, {"child3", [node()]}}
  end

  test "await", %{hub_id: hub_id} = _context do
    [child_spec1, child_spec2] = ProcessHub.Utility.Bag.gen_child_specs(2)
    assert ProcessHub.await(:wrong_input) === {:error, :invalid_await_input}

    assert ProcessHub.start_child(hub_id, child_spec1) |> ProcessHub.await() ===
             {:error, :invalid_await_input}

    {:ok, {child_id, pids}} =
      ProcessHub.start_child(hub_id, child_spec2, async_wait: true) |> ProcessHub.await()

    assert child_id === child_spec2.id
    assert is_list(pids)
  end
end
