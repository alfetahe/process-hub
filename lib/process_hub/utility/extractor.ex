defmodule ProcessHub.Utility.Extractor do
  @moduledoc """
  Utility module for extracting information from datasets.
  """

  # TODO: add tests.
  @doc """
  Extracts child_ids with their PIDs of the local nodes.
  """
  def local_cid_pid_pairs(registry_items) do
    node = node()

    # TODO: maybe we can use match instead.
    Enum.reduce(registry_items, %{}, fn
      {child_id, {_cspec, node_pids, _metadata}}, acc when is_list(node_pids) ->
        case Enum.find(node_pids, fn {n, _pid} -> n == node end) do
          {^node, pid} -> Map.put(acc, child_id, pid)
          nil -> acc
        end

      _other, acc ->
        acc
    end)
  end
end
