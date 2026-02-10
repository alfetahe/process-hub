defmodule Test.Utility.ExtractorTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Utility.Extractor

  describe "local_cid_pid_pairs/1" do
    test "extracts local node pid pairs" do
      local = node()
      pid1 = self()
      pid2 = spawn(fn -> :timer.sleep(:infinity) end)

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
end
