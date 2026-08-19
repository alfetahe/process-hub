defmodule Test.Utility.ExtractorTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Utility.Extractor

  describe "local_cid_pid_pairs/1" do
    test "extracts local node pid pairs" do
      local = node()
      pid1 = self()

      pid2 =
        spawn(fn ->
          receive do
            _ -> :ok
          end
        end)

      items = %{
        :child1 => {%{id: :child1}, [{local, pid1}], %{}},
        :child2 => {%{id: :child2}, [{local, pid2}], %{}}
      }

      result = Extractor.local_cid_pid_pairs(items)
      assert result[:child1] == pid1
      assert result[:child2] == pid2

      Process.exit(pid2, :kill)
    end

    test "returns empty map when all items are from remote nodes" do
      items = %{
        :child1 => {%{id: :child1}, [{:remote@host, self()}], %{}},
        :child2 => {%{id: :child2}, [{:other@host, self()}], %{}}
      }

      result = Extractor.local_cid_pid_pairs(items)
      assert result == %{}
    end

    test "filters mixed local and remote items" do
      local = node()
      pid = self()

      items = %{
        :local_child => {%{id: :local_child}, [{local, pid}], %{}},
        :remote_child => {%{id: :remote_child}, [{:remote@host, pid}], %{}}
      }

      result = Extractor.local_cid_pid_pairs(items)
      assert result == %{local_child: pid}
    end

    test "handles items with multiple node_pids" do
      local = node()
      pid = self()

      items = %{
        :child1 => {%{id: :child1}, [{:remote@host, pid}, {local, pid}], %{}}
      }

      result = Extractor.local_cid_pid_pairs(items)
      assert result[:child1] == pid
    end

    test "handles empty input" do
      assert Extractor.local_cid_pid_pairs(%{}) == %{}
    end

    test "skips items with non-list node_pids" do
      items = %{
        :child1 => {%{id: :child1}, :not_a_list, %{}}
      }

      result = Extractor.local_cid_pid_pairs(items)
      assert result == %{}
    end

    test "handles empty node_pids list" do
      items = %{
        :child1 => {%{id: :child1}, [], %{}}
      }

      result = Extractor.local_cid_pid_pairs(items)
      assert result == %{}
    end
  end

  describe "local_and_empty_children/1" do
    setup do
      table = :test_extractor_hub

      if :ets.whereis(table) != :undefined do
        :ets.delete(table)
      end

      :ets.new(table, [:named_table, :set, :public])

      on_exit(fn ->
        if :ets.whereis(table) != :undefined do
          :ets.delete(table)
        end
      end)

      %{table: table}
    end

    test "returns children on local node", %{table: table} do
      local = node()
      cspec = %{id: :child1, start: {Agent, :start_link, [fn -> nil end]}}

      :ets.insert(table, {:child1, {cspec, [{local, self()}], %{some: :meta}}})

      result = Extractor.local_and_empty_children(table)

      assert map_size(result) == 1
      assert {^cspec, [{^local, _pid}], %{some: :meta}} = result[:child1]
    end

    test "returns children with empty node_pids", %{table: table} do
      cspec = %{id: :child2, start: {Agent, :start_link, [fn -> nil end]}}

      :ets.insert(table, {:child2, {cspec, [], %{}}})

      result = Extractor.local_and_empty_children(table)

      assert map_size(result) == 1
      assert {^cspec, [], %{}} = result[:child2]
    end

    test "excludes children only on remote nodes", %{table: table} do
      cspec = %{id: :child3, start: {Agent, :start_link, [fn -> nil end]}}

      :ets.insert(table, {:child3, {cspec, [{:remote@host, self()}], %{}}})

      result = Extractor.local_and_empty_children(table)

      assert result == %{}
    end

    test "handles TTL tuple format", %{table: table} do
      local = node()
      cspec = %{id: :child4, start: {Agent, :start_link, [fn -> nil end]}}

      :ets.insert(table, {:child4, {cspec, [{local, self()}], %{ttl: true}}, 30_000})

      result = Extractor.local_and_empty_children(table)

      assert map_size(result) == 1
      assert {^cspec, [{^local, _pid}], %{ttl: true}} = result[:child4]
    end

    test "handles mixed local, remote, and empty entries", %{table: table} do
      local = node()
      cspec_local = %{id: :local, start: {Agent, :start_link, [fn -> nil end]}}
      cspec_remote = %{id: :remote, start: {Agent, :start_link, [fn -> nil end]}}
      cspec_empty = %{id: :empty, start: {Agent, :start_link, [fn -> nil end]}}
      cspec_ttl = %{id: :with_ttl, start: {Agent, :start_link, [fn -> nil end]}}

      :ets.insert(table, {:local, {cspec_local, [{local, self()}], %{}}})
      :ets.insert(table, {:remote, {cspec_remote, [{:remote@host, self()}], %{}}})
      :ets.insert(table, {:empty, {cspec_empty, [], %{}}})
      :ets.insert(table, {:with_ttl, {cspec_ttl, [{local, self()}], %{}}, 60_000})

      result = Extractor.local_and_empty_children(table)

      assert map_size(result) == 3
      assert Map.has_key?(result, :local)
      assert Map.has_key?(result, :empty)
      assert Map.has_key?(result, :with_ttl)
      refute Map.has_key?(result, :remote)
    end
  end
end
