defmodule Test.Service.ProcessRegistryTest do
  require Integer
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.Storage

  use ExUnit.Case

  setup_all %{} do
    Test.Helper.SetupHelper.setup_base(%{}, :process_registry_test)
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
        {:child1, {%{id: :child1, start: :mfa}, [{:node1, :pid1}, {:node2, :pid2}], %{}}},
        {:child2, {%{id: :child2, start: :mfa}, [{:node3, :pid1}, {:node4, :pid2}], %{}}},
        {:child3, {%{id: :child3, start: :mfa}, [{:node5, :pid1}, {:node6, :pid2}], %{}}}
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

  test "bulk insert", %{hub_id: hub_id, hub: hub} = _context do
    Storage.clear_all(hub_id)

    hook = %HookManager{
      id: :process_registry_test_bulk_insert,
      m: :erlang,
      f: :send,
      a: [self(), :bulk_insert_test]
    }

    HookManager.register_handler(hub.storage.hook, Hook.registry_pid_inserted(), hook)

    assert ProcessRegistry.dump(hub_id) === %{}

    insert_data = [
      {:child1, {%{id: :child1, start: :mfa}, [{:node1, :pid1}, {:node2, :pid2}], %{}}},
      {:child2, {%{id: :child2, start: :mfa}, [{:node3, :pid1}, {:node4, :pid2}], %{}}},
      {:child3, {%{id: :child3, start: :mfa}, [{:node5, :pid1}, {:node6, :pid2}], %{}}},
      {:child4, {%{id: :child4, start: :mfa}, [{:node7, :pid1}, {:node8, :pid2}], %{}}}
    ]

    ProcessRegistry.bulk_insert(hub_id, Map.new(insert_data), hook_storage: hub.storage.hook)

    Enum.each(1..length(insert_data), fn _ ->
      assert_receive :bulk_insert_test
    end)

    assert ProcessRegistry.dump(hub_id) === insert_data |> Map.new()
  end

  test "bulk delete", %{hub_id: hub_id, hub: hub} = _context do
    handler = %HookManager{
      id: :process_registry_test_bulk_delete,
      m: :erlang,
      f: :send,
      a: [self(), :bulk_delete]
    }

    HookManager.register_handler(hub.storage.hook, Hook.registry_pid_removed(), handler)

    assert ProcessRegistry.dump(hub_id) === %{}

    insert_data = [
      {:child1, {%{id: :child1, start: :mfa}, [{:node1, :pid1}, {:node2, :pid2}], %{}}},
      {:child2, {%{id: :child2, start: :mfa}, [{:node3, :pid1}, {:node4, :pid2}], %{}}},
      {:child3, {%{id: :child3, start: :mfa}, [{:node5, :pid1}, {:node6, :pid2}], %{}}}
    ]

    del_data =
      Enum.map(insert_data, fn {child_id, {_, child_nodes, _}} ->
        {child_id, Enum.map(child_nodes, fn {node, _pid} -> node end)}
      end)
      |> Map.new()

    ProcessRegistry.bulk_insert(hub_id, Map.new(insert_data))
    ProcessRegistry.bulk_delete(hub_id, del_data, hook_storage: hub.storage.hook)

    Enum.each(1..length(insert_data), fn _ ->
      assert_receive :bulk_delete
    end)

    assert ProcessRegistry.dump(hub_id) === %{}
  end

  test "clear all", %{hub_id: hub_id} = _context do
    some_data =
      [
        {:child1, {%{id: :child1, start: :mfa}, :child_nodes1, %{}}},
        {:child2, {%{id: :child2, start: :mfa}, :child_nodes2, %{}}},
        {:child3, {%{id: :child3, start: :mfa}, :child_nodes3, %{}}}
      ]
      |> Map.new()

    ProcessRegistry.bulk_insert(hub_id, some_data)
    ProcessRegistry.clear_all(hub_id)

    assert ProcessRegistry.dump(hub_id) === %{}
  end

  test "insert", %{hub_id: hub_id, hub: hub} = _context do
    handler = %HookManager{
      id: :process_registry_test_insert_test,
      m: :erlang,
      f: :send,
      a: [self(), :insert_test]
    }

    HookManager.register_handler(hub.storage.hook, Hook.registry_pid_inserted(), handler)

    children = %{
      1 =>
        {%{id: 1, start: {:firstmod, :firstfunc, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}],
         %{}},
      2 =>
        {%{id: 2, start: {:secondmod, :secondfunc, [3, 4]}}, [{:node3, "pid3"}, {:node4, "pid4"}],
         %{}},
      3 =>
        {%{id: 3, start: {:thirdmod, :thirdfunc, [5, 6]}}, [{:node5, "pid5"}, {:node6, :pid6}],
         %{}}
    }

    Enum.each(children, fn {key, {child_spec, child_nodes, metadata}} ->
      hook_storage =
        case Integer.is_odd(key) do
          true -> hub.storage.hook
          false -> nil
        end

      ProcessRegistry.insert(hub_id, child_spec, child_nodes,
        hook_storage: hook_storage,
        metadata: metadata
      )
    end)

    Enum.each(1..2, fn _ ->
      assert_receive :insert_test
    end)

    assert ProcessRegistry.dump(hub_id) === children
  end

  test "delete child", %{hub_id: hub_id, hub: hub} = _context do
    handler = %HookManager{
      id: :process_registry_test_delete_test,
      m: :erlang,
      f: :send,
      a: [self(), :delete_test]
    }

    HookManager.register_handler(hub.storage.hook, Hook.registry_pid_removed(), handler)

    children = %{
      1 => {%{id: 1, start: {:firstmod, :firstfunc, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}]},
      2 =>
        {%{id: 2, start: {:secondmod, :secondfunc, [3, 4]}}, [{:node3, "pid3"}, {:node4, "pid4"}]},
      3 => {%{id: 3, start: {:thirdmod, :thirdfunc, [5, 6]}}, [{:node5, "pid5"}, {:node6, :pid6}]}
    }

    Enum.each(children, fn {key, {child_spec, child_nodes}} ->
      ProcessRegistry.insert(hub_id, child_spec, child_nodes)

      if Integer.is_odd(key) do
        ProcessRegistry.delete(hub_id, key, hook_storage: hub.storage.hook)
      else
        ProcessRegistry.delete(hub_id, key)
      end
    end)

    Enum.each(1..2, fn _ ->
      assert_receive :delete_test
    end)

    assert ProcessRegistry.dump(hub_id) === %{}
  end

  test "child lookup", %{hub_id: hub_id} = _context do
    child_spec = %{id: "child_lookup_id", start: {:firstmod, :firstfunc, [1, 2]}}
    child_nodes = [{:node1, :pid1}, {:node2, :pid2}, {:node3, "pid3"}]
    ProcessRegistry.insert(hub_id, child_spec, child_nodes)

    assert ProcessRegistry.lookup(hub_id, "child_lookup_id") === {child_spec, child_nodes}
    assert ProcessRegistry.lookup(hub_id, "none_exist") === nil
  end

  test "with tag", %{hub_id: hub_id} = _context do
    tag = "test_tag"

    child_spec = %{id: "match_tag_test", start: {:firstmod, :firstfunc, [1, 2]}}
    child_nodes = [{:node1, :pid1}, {:node2, :pid2}, {:node3, "pid3"}]
    ProcessRegistry.insert(hub_id, child_spec, child_nodes, metadata: %{tag: tag})

    assert ProcessRegistry.match_tag(hub_id, tag) === [
             {"match_tag_test", [node1: :pid1, node2: :pid2, node3: "pid3"]}
           ]

    assert ProcessRegistry.match_tag(hub_id, "none_exist") === []
  end

  test "registry", %{hub_id: hub_id} = _context do
    children = %{
      1 =>
        {%{id: 1, start: {:firstmod, :firstfunc, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}],
         %{}},
      2 =>
        {%{id: 2, start: {:secondmod, :secondfunc, [3, 4]}}, [{:node3, "pid3"}, {:node4, "pid4"}],
         %{}},
      3 =>
        {%{id: 3, start: {:thirdmod, :thirdfunc, [5, 6]}}, [{:node5, :pid5}, {:node6, "pid6"}],
         %{}}
    }

    Enum.each(children, fn {_key, {child_spec, child_nodes, metadata}} ->
      ProcessRegistry.insert(hub_id, child_spec, child_nodes, metadata: metadata)
    end)

    assert ProcessRegistry.dump(hub_id) === children
  end

  test "dump", %{hub_id: hub_id} = _context do
    children = %{
      1 =>
        {%{id: 1, start: {:firstmodx, :firstfuncx, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}],
         %{}},
      2 =>
        {%{id: 2, start: {:secondmodx, :secondfuncx, [3, 4]}},
         [{:node3, "pid3"}, {:node4, "pid4"}], %{}},
      3 =>
        {%{id: 3, start: {:thirdmodx, :thirdfuncx, [5, 6]}}, [{:node5, :pid5}, {:node6, "pid6"}],
         %{}}
    }

    Enum.each(children, fn {_key, {child_spec, child_nodes, metadata}} ->
      ProcessRegistry.insert(hub_id, child_spec, child_nodes, metadata: metadata)
    end)

    assert ProcessRegistry.dump(hub_id) === children
  end

  test "process list local", %{hub_id: hub_id} = _context do
    children = %{
      1 => {%{id: 1, start: {:firstmod, :firstfunc, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}]},
      2 =>
        {%{id: 2, start: {:secondmod, :secondfunc, [3, 4]}},
         [{:"process_hub@127.0.0.1", "pid3"}, {:node4, "pid4"}, {:node5, "pid5"}]},
      3 =>
        {%{id: 3, start: {:thirdmod, :thirdfunc, [5, 6]}},
         [{:"process_hub@127.0.0.1", :pid5}, {:node6, "pid6"}]}
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
      1 =>
        {%{id: 1, start: {:firstmod, :firstfunc, [1, 2]}}, [{:node1, :pid1}, {:node2, :pid2}],
         %{}},
      2 =>
        {%{id: 2, start: {:secondmod, :secondfunc, [3, 4]}}, [{:node3, :pid3}, {:node4, :pid4}],
         %{}}
    }

    local = %{
      3 => {%{id: 3, start: {:firstmod, :firstfunc, [1, 2]}}, [{local_node, :pid2}], %{}},
      4 => {%{id: 4, start: {:secondmod, :secondfunc, [3, 4]}}, [{local_node, :pid1}], %{}}
    }

    local_n_remote = %{
      5 =>
        {%{id: 5, start: {:firstmod, :firstfunc, [1, 2]}},
         [{local_node, :pid1}, {:node2, "pid2"}], %{}},
      6 =>
        {%{id: 6, start: {:secondmod, :secondfunc, [3, 4]}},
         [{local_node, :pid3}, {:node4, "pid4"}], %{}}
    }

    Map.merge(remote, local)
    |> Map.merge(local_n_remote)
    |> Enum.each(fn {_key, {child_spec, child_nodes, metadata}} ->
      ProcessRegistry.insert(hub_id, child_spec, child_nodes, metadata: metadata)
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

  test "update", %{hub_id: hub_id} = _context do
    cid = "child_update_id"
    child_spec = %{id: cid, start_link: {:mod1, :fn1, [1, 2]}}
    child_nodes = [{:node1, :pid1}]
    ProcessRegistry.insert(hub_id, child_spec, child_nodes)

    init_res = ProcessRegistry.lookup(hub_id, cid, with_metadata: true)
    err = ProcessRegistry.update(hub_id, "none", fn nil, nil, nil -> nil end)

    result =
      ProcessRegistry.update(hub_id, cid, fn child_spec, child_nodes, _m ->
        {
          Map.put(child_spec, :start_link, {:mod2, :fn2, [3, 4]}),
          [{:node1, :pid1}, child_nodes],
          %{update: "hello world"}
        }
      end)

    {cs, cn, m} = ProcessRegistry.lookup(hub_id, cid, with_metadata: true)

    assert init_res === {child_spec, child_nodes, %{}}
    assert err === {:error, "No child found"}

    assert result === :ok
    assert cs === %{id: cid, start_link: {:mod2, :fn2, [3, 4]}}
    assert cn === [{:node1, :pid1}, child_nodes]
    assert m === %{update: "hello world"}
  end
end
