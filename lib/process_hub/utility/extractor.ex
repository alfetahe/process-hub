defmodule ProcessHub.Utility.Extractor do
  @moduledoc """
  Utility module for extracting information from datasets.
  """

  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Storage

  @doc """
  Extracts child_ids with their PIDs of the local nodes.
  """
  def local_cid_pid_pairs(registry_items) do
    node = node()

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

  @doc """
  Extracts child_ids with their child_spec, node_pids, and metadata for local nodes
  or empty node_pids.
  """
  @spec local_and_empty_children(ProcessHub.hub_id()) :: %{
          ProcessHub.child_id() =>
            {ProcessHub.child_spec(), [{node(), pid()}], ProcessRegistry.metadata()}
        }
  def local_and_empty_children(hub_id) do
    local_node = node()

    Storage.foldl_entries(hub_id, %{}, fn
      {child_id, {_child_spec, node_pids, _metadata} = value}, acc ->
        if Keyword.has_key?(node_pids, local_node) or node_pids == [] do
          Map.put(acc, child_id, value)
        else
          acc
        end
    end)
  end
end
