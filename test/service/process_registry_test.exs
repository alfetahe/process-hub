defmodule Test.Service.ProcessRegistryTest do
  require Integer
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook

  use ExUnit.Case

  setup_all %{} do
    Test.Helper.SetupHelper.setup_base(%{}, :children_reg_test)
  end

  setup %{hub_id: hub_id} = context do
    on_exit(:clear_table, fn ->
      ProcessRegistry.clear_all(hub_id)
    end)

    context
  end

  test "contains children", %{hub_id: hub_id} = _context do
    insert_data =
      [
        {:child1, {%{id: :child1, start: :mfa}, [{:node1, :pid1}, {:node2, :pid2}]}},
        {:child2, {%{id: :child2, start: :mfa}, [{:node3, :pid1}, {:node4, :pid2}]}},
        {:child3, {%{id: :child3, start: :mfa}, [{:node5, :pid1}, {:node6, :pid2}]}}
      ]
      |> Map.new()

    ProcessRegistry.bulk_insert(hub_id, insert_data)

    contains =
      ProcessRegistry.contains_children(hub_id, [:nochild, :child1, :child2, :child3, :child3])

    assert length(contains) === 3

    Enum.each(contains, fn child_id ->
      assert Enum.member?([:child1, :child2, :child3], child_id)
    end)
  end

  test "bulk insert", %{hub_id: hub_id} = _context do
    Cachex.purge(ProcessHub.Utility.Name.registry(hub_id))

    hook = {:erlang, :send, [self(), :bulk_insert_test]}
    HookManager.register_handlers(hub_id, Hook.registry_pid_inserted(), [hook])

    assert ProcessRegistry.registry(hub_id) === %{}

    insert_data = [
      {:child1, {%{id: :child1, start: :mfa}, [{:node1, :pid1}, {:node2, :pid2}]}},
      {:child2, {%{id: :child2, start: :mfa}, [{:node3, :pid1}, {:node4, :pid2}]}},
      {:child3, {%{id: :child3, start: :mfa}, [{:node5, :pid1}, {:node6, :pid2}]}},
      {:child4, {%{id: :child4, start: :mfa}, [{:node7, :pid1}, {:node8, :pid2}]}}
    ]

    ProcessRegistry.bulk_insert(hub_id, Map.new(insert_data))

    Enum.each(1..length(insert_data), fn _ ->
      assert_receive :bulk_insert_test
    end)

    assert ProcessRegistry.registry(hub_id) === insert_data |> Map.new()
  end

  test "bulk delete", %{hub_id: hub_id} = _context do
    hook = {:erlang, :send, [self(), :bulk_delete]}
    HookManager.register_handlers(hub_id, Hook.registry_pid_removed(), [hook])

    assert ProcessRegistry.registry(hub_id) === %{}

    insert_data = [
      {:child1, {%{id: :child1, start: :mfa}, [{:node1, :pid1}, {:node2, :pid2}]}},
      {:child2, {%{id: :child2, start: :mfa}, [{:node3, :pid1}, {:node4, :pid2}]}},
      {:child3, {%{id: :child3, start: :mfa}, [{:node5, :pid1}, {:node6, :pid2}]}}
    ]

    del_data =
      Enum.map(insert_data, fn {child_id, {_, child_nodes}} ->
        {child_id, Enum.map(child_nodes, fn {node, _pid} -> node end)}
      end)
      |> Map.new()

    ProcessRegistry.bulk_insert(hub_id, Map.new(insert_data))
    ProcessRegistry.bulk_delete(hub_id, del_data)

    Enum.each(1..length(insert_data), fn _ ->
      assert_receive :bulk_delete
    end)

    assert ProcessRegistry.registry(hub_id) === %{}
  end

  test "clear all", %{hub_id: hub_id} = _context do
    some_data =
      [
        {:child1, {%{id: :child1, start: :mfa}, :child_nodes1}},
        {:child2, {%{id: :child2, start: :mfa}, :child_nodes2}},
        {:child3, {%{id: :child3, start: :mfa}, :child_nodes3}}
      ]
      |> Map.new()

    ProcessRegistry.bulk_insert(hub_id, some_data)
    ProcessRegistry.clear_all(hub_id)

    assert ProcessRegistry.registry(hub_id) === %{}
  end

  test "insert", %{hub_id: hub_id} = _context do
    hook = {:erlang, :send, [self(), :insert_test]}
    HookManager.register_handlers(hub_id, Hook.registry_pid_inserted(), [hook])

    children = %{
      1 => {%{id: 1, start: {:firstmod, :firstfunc, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}]},
      2 =>
        {%{id: 2, start: {:secondmod, :secondfunc, [3, 4]}}, [{:node3, "pid3"}, {:node4, "pid4"}]},
      3 => {%{id: 3, start: {:thirdmod, :thirdfunc, [5, 6]}}, [{:node5, "pid5"}, {:node6, :pid6}]}
    }

    Enum.each(children, fn {key, {child_spec, child_nodes}} ->
      skip_hooks =
        case Integer.is_odd(key) do
          true -> false
          false -> true
        end

      ProcessRegistry.insert(hub_id, child_spec, child_nodes, skip_hooks: skip_hooks)
    end)

    Enum.each(1..2, fn _ ->
      assert_receive :insert_test
    end)

    assert ProcessRegistry.registry(hub_id) === children
  end

  test "delete child", %{hub_id: hub_id} = _context do
    hook = {:erlang, :send, [self(), :delete_test]}
    HookManager.register_handlers(hub_id, Hook.registry_pid_removed(), [hook])

    children = %{
      1 => {%{id: 1, start: {:firstmod, :firstfunc, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}]},
      2 =>
        {%{id: 2, start: {:secondmod, :secondfunc, [3, 4]}}, [{:node3, "pid3"}, {:node4, "pid4"}]},
      3 => {%{id: 3, start: {:thirdmod, :thirdfunc, [5, 6]}}, [{:node5, "pid5"}, {:node6, :pid6}]}
    }

    Enum.each(children, fn {key, {child_spec, child_nodes}} ->
      ProcessRegistry.insert(hub_id, child_spec, child_nodes)

      if Integer.is_odd(key) do
        ProcessRegistry.delete(hub_id, key)
      else
        ProcessRegistry.delete(hub_id, key, skip_hooks: true)
      end
    end)

    Enum.each(1..2, fn _ ->
      assert_receive :delete_test
    end)

    assert ProcessRegistry.registry(hub_id) === %{}
  end

  test "child lookup", %{hub_id: hub_id} = _context do
    child_spec = %{id: "child_lookup_id", start: {:firstmod, :firstfunc, [1, 2]}}
    child_nodes = [{:node1, :pid1}, {:node2, :pid2}, {:node3, "pid3"}]
    ProcessRegistry.insert(hub_id, child_spec, child_nodes)

    assert ProcessRegistry.lookup(hub_id, "child_lookup_id") === {child_spec, child_nodes}
    assert ProcessRegistry.lookup(hub_id, "none_exist") === nil
  end

  test "registry", %{hub_id: hub_id} = _context do
    children = %{
      1 => {%{id: 1, start: {:firstmod, :firstfunc, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}]},
      2 =>
        {%{id: 2, start: {:secondmod, :secondfunc, [3, 4]}}, [{:node3, "pid3"}, {:node4, "pid4"}]},
      3 => {%{id: 3, start: {:thirdmod, :thirdfunc, [5, 6]}}, [{:node5, :pid5}, {:node6, "pid6"}]}
    }

    Enum.each(children, fn {_key, {child_spec, child_nodes}} ->
      ProcessRegistry.insert(hub_id, child_spec, child_nodes)
    end)

    assert ProcessRegistry.registry(hub_id) === children
  end

  test "process list local", %{hub_id: hub_id} = _context do
    children = %{
      1 => {%{id: 1, start: {:firstmod, :firstfunc, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}]},
      2 =>
        {%{id: 2, start: {:secondmod, :secondfunc, [3, 4]}},
         [{:"ex_unit@127.0.0.1", "pid3"}, {:node4, "pid4"}, {:node5, "pid5"}]},
      3 =>
        {%{id: 3, start: {:thirdmod, :thirdfunc, [5, 6]}},
         [{:"ex_unit@127.0.0.1", :pid5}, {:node6, "pid6"}]}
    }

    Enum.each(children, fn {_key, {child_spec, child_nodes}} ->
      ProcessRegistry.insert(hub_id, child_spec, child_nodes)
    end)

    assert ProcessRegistry.process_list(hub_id, :local) === [{2, "pid3"}, {3, :pid5}]
  end

  test "process list global", %{hub_id: hub_id} = _context do
    children = %{
      1 => {%{id: 1, start: {:firstmod, :firstfunc, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}]},
      2 =>
        {%{id: 2, start: {:secondmod, :secondfunc, [3, 4]}}, [{:node3, "pid3"}, {:node4, "pid4"}]},
      3 => {%{id: 3, start: {:thirdmod, :thirdfunc, [5, 6]}}, [{:node5, :pid5}, {:node6, "pid6"}]}
    }

    Enum.each(children, fn {_key, {child_spec, child_nodes}} ->
      ProcessRegistry.insert(hub_id, child_spec, child_nodes)
    end)

    children_formatted = Enum.map(children, fn {child_id, {_cs, nodes}} -> {child_id, nodes} end)

    assert ProcessRegistry.process_list(hub_id, :global) === children_formatted
  end

  test "local data", %{hub_id: hub_id} = _context do
    local_node = node()

    remote = %{
      1 => {%{id: 1, start: {:firstmod, :firstfunc, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}]},
      2 =>
        {%{id: 2, start: {:secondmod, :secondfunc, [3, 4]}}, [{:node3, :pid3}, {:node4, :pid4}]}
    }

    local = %{
      3 => {%{id: 3, start: {:firstmod, :firstfunc, [1, 2]}}, [{local_node, :pid2}]},
      4 => {%{id: 4, start: {:secondmod, :secondfunc, [3, 4]}}, [{local_node, :pid1}]}
    }

    local_n_remote = %{
      5 =>
        {%{id: 5, start: {:firstmod, :firstfunc, [1, 2]}},
         [{local_node, :pid1}, {:node2, "pid2"}]},
      6 =>
        {%{id: 6, start: {:secondmod, :secondfunc, [3, 4]}},
         [{local_node, :pid3}, {:node4, "pid4"}]}
    }

    Map.merge(remote, local)
    |> Map.merge(local_n_remote)
    |> Enum.each(fn {_key, {child_spec, child_nodes}} ->
      ProcessRegistry.insert(hub_id, child_spec, child_nodes)
    end)

    assert Enum.sort(ProcessRegistry.local_data(hub_id)) ===
             Map.merge(local, local_n_remote) |> Map.to_list()
  end

  test "local child specs", %{hub_id: hub_id} = _context do
    local_node = node()

    remote = %{
      1 => {%{id: 1, start: {:firstmod, :firstfunc, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}]},
      2 =>
        {%{id: 2, start: {:secondmod, :secondfunc, [3, 4]}}, [{:node3, :pid3}, {:node4, :pid4}]}
    }

    local = %{
      3 => {%{id: 3, start: {:firstmod, :firstfunc, [1, 2]}}, [{local_node, :pid2}]},
      4 => {%{id: 4, start: {:secondmod, :secondfunc, [3, 4]}}, [{local_node, :pid1}]}
    }

    local_n_remote = %{
      5 =>
        {%{id: 5, start: {:firstmod, :firstfunc, [1, 2]}},
         [{local_node, :pid1}, {:node2, "pid2"}]},
      6 =>
        {%{id: 6, start: {:secondmod, :secondfunc, [3, 4]}},
         [{local_node, :pid3}, {:node4, "pid4"}]}
    }

    Map.merge(remote, local)
    |> Map.merge(local_n_remote)
    |> Enum.each(fn {_key, {child_spec, child_nodes}} ->
      ProcessRegistry.insert(hub_id, child_spec, child_nodes)
    end)

    formatted_data =
      Map.merge(local, local_n_remote)
      |> Enum.map(fn {_cid, {child_spec, _nodes}} -> child_spec end)
      |> Enum.sort()

    assert Enum.sort(ProcessRegistry.local_child_specs(hub_id)) === formatted_data
  end

  # test "handle children emit", %{hub_id: hub_id} = _context do
  #   local_node = node()

  #   remote = %{
  #     1 => {%{id: 1, start: {:firstmod, :firstfunc, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}]},
  #     2 =>
  #       {%{id: 2, start: {:secondmod, :secondfunc, [3, 4]}}, [{:node3, :pid3}, {:node4, :pid4}]}
  #   }

  #   local = %{
  #     "3" => {%{id: "3", start: {:firstmod, :firstfunc, [1, 2]}}, [{local_node, :pid2}]},
  #     "4" => {%{id: "4", start: {:secondmod, :secondfunc, [3, 4]}}, [{local_node, :pid1}]}
  #   }

  #   local_n_remote = %{
  #     :five =>
  #       {%{id: :five, start: {:firstmod, :firstfunc, [1, 2]}},
  #        [{local_node, :pid1}, {:node2, "pid2"}]},
  #     :six =>
  #       {%{id: :six, start: {:secondmod, :secondfunc, [3, 4]}},
  #        [{local_node, :pid3}, {:node4, "pid4"}]}
  #   }

  #   Map.merge(remote, local)
  #   |> Map.merge(local_n_remote)
  #   |> Enum.each(fn {_key, child} ->
  #     ProcessRegistry.insert_child(hub_id, child)
  #   end)

  #   remote1 = [
  #     {%{id: :seven, start: {:firstmod, :firstfunc, [1, 2]}}, :pidseven},
  #     {%{id: :eigth, start: {:firstmod, :firstfunc, [1, 2]}}, :pideigth}
  #   ]

  #   remote2 = [
  #     {%{id: :seven, start: {:firstmod, :firstfunc, [1, 2]}}, :pidseven},
  #     {%{id: :eigth, start: {:firstmod, :firstfunc, [1, 2]}}, :pideigth}
  #   ]

  #   ProcessRegistry.handle_children_emit(hub_id, remote1, :remote1)
  #   ProcessRegistry.handle_children_emit(hub_id, remote2, :remote2)

  #   formatted_data =
  #     Map.merge(local, remote)
  #     |> Map.merge(local_n_remote)
  #     |> Map.to_list()

  #   formatted_data =
  #     formatted_data ++
  #       [
  #         {:seven,
  #          {%{id: :seven, start: {:firstmod, :firstfunc, [1, 2]}},
  #           [{:remote1, :pidseven}, {:remote2, :pidseven}]}},
  #         {:eigth,
  #          {%{id: :eigth, start: {:firstmod, :firstfunc, [1, 2]}},
  #           [{:remote1, :pideigth}, {:remote2, :pideigth}]}}
  #       ]

  #   assert Enum.sort(ProcessRegistry.children(hub_id)) === Enum.sort(formatted_data)
  # end
end
