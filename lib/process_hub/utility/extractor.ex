defmodule ProcessHub.Utility.Extractor do
  @moduledoc """
  Utility module for extracting information from datasets.
  """

  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.ProcessRegistry

  # TODO: add tests. Maybe remove.
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

  # TODO: add tests.
  @spec local_and_empty_children(ProcessHub.hub_id()) :: %{
          ProcessHub.child_id() =>
            {ProcessHub.child_spec(), [{node(), pid()}], ProcessRegistry.metadata()}
        }
  def local_and_empty_children(hub_id) do
    local_node = node()

    fold_handler = fn acc, child_id, child_spec, node_pids, metadata, local_node ->
      if Keyword.has_key?(node_pids, local_node) || node_pids == [] do
        Map.put(acc, child_id, {child_spec, node_pids, metadata})
      else
        acc
      end
    end

    Storage.foldl(hub_id, %{}, fn
      {child_id, {child_spec, node_pids, metadata}}, acc ->
        fold_handler.(acc, child_id, child_spec, node_pids, metadata, local_node)

      {child_id, {child_spec, node_pids, metadata}, _ttl}, acc ->
        fold_handler.(acc, child_id, child_spec, node_pids, metadata, local_node)
    end)
  end
end
