defmodule ProcessHub.Service.State do
  @moduledoc """
  The state service provides API functions for managing the state of the hub.
  """

  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Hub
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.Synchronizer

  @peer_call_ms 5_000

  @doc "Returns a boolean indicating whether the hub cluster is partitioned."
  @spec is_partitioned?(Hub.t()) :: boolean
  def is_partitioned?(hub) do
    case Registry.lookup(hub.procs.system_registry, "dist_sup") do
      [] -> true
      [{pid, _}] -> !Process.alive?(pid)
      _ -> false
    end
  end

  @doc """
  Terminates the local distributed supervisor.

  The children it ran are stopped with it, so this node withdraws its claim on
  them and remembers them for `toggle_quorum_success/1`: a hub in partition
  mode never tells the cluster it runs a child it does not.
  """
  @spec toggle_quorum_failure(Hub.t()) :: :ok | {:error, :already_partitioned}
  def toggle_quorum_failure(hub) do
    unless is_partitioned?(hub) do
      local_rows = ProcessRegistry.local_data(hub.hub_id)
      Supervisor.terminate_child(hub.procs.initializer, :dist_sup)

      held = Storage.get(hub.storage.misc, StorageKey.plh()) || MapSet.new()
      held = MapSet.union(held, MapSet.new(local_rows, &elem(&1, 0)))
      Storage.insert(hub.storage.misc, StorageKey.plh(), held)

      local_node = node()

      ProcessRegistry.withdraw_observations(hub.hub_id, local_rows, fn _id, n ->
        n === local_node
      end)

      :ok
    else
      {:error, :already_partitioned}
    end
  end

  @doc """
  Restarts the local distributed supervisor.

  It comes back empty. The rows of the reachable hub nodes that kept their
  quorum are merged first, the way a join merges them, so this node sees where
  their side runs each child. Of the children this node held when it stopped,
  it starts again only those no node runs; the node-up redistribution moves
  back the others that belong here. A child stopped on the other side
  meanwhile is one no node runs, so it starts again too; with `:auto_recovery`
  the next round stops it.
  """
  @spec toggle_quorum_success(Hub.t()) :: :ok | {:error, :not_partitioned}
  def toggle_quorum_success(hub) do
    if is_partitioned?(hub) do
      merge_from_quorum(hub)
      Supervisor.restart_child(hub.procs.initializer, :dist_sup)
      restart_held(hub)

      :ok
    else
      {:error, :not_partitioned}
    end
  end

  # A node still in partition mode holds rows as stale as this one's and is
  # not asked; a node that does not answer adds nothing.
  defp merge_from_quorum(hub) do
    local_node = node()

    observed =
      for {:ok, rows} <-
            hub.storage.misc
            |> Cluster.nodes([:connected])
            |> with_quorum(hub.hub_id)
            |> :erpc.multicall(ProcessRegistry, :dump_all, [hub.hub_id], @peer_call_ms),
          {_child_id, {spec, node_pids, meta}} <- rows,
          {node, pid} <- node_pids,
          node !== local_node,
          reduce: %{} do
        acc -> Map.update(acc, node, [{spec, pid, meta}], &[{spec, pid, meta} | &1])
      end

    Synchronizer.append_data(hub, observed)
  end

  defp with_quorum(nodes, hub_id) do
    nodes
    |> Enum.zip(:erpc.multicall(nodes, ProcessHub, :is_partitioned?, [hub_id], @peer_call_ms))
    |> Enum.flat_map(fn
      {node, {:ok, false}} -> [node]
      _partitioned_or_silent -> []
    end)
  end

  # The supervisor comes back empty: the hub withdrew its claim on every local
  # child when it stopped. Each held child no node runs is started here and
  # bound to this node again.
  defp restart_held(hub) do
    held = Storage.get(hub.storage.misc, StorageKey.plh()) || MapSet.new()
    Storage.remove(hub.storage.misc, StorageKey.plh())

    for child_id <- held,
        {spec, [], meta} <- [
          ProcessRegistry.lookup(hub.hub_id, child_id, include_empty: true, with_metadata: true)
        ],
        {:ok, pid} <- [started(DistributedSupervisor.start_child(hub.procs.dist_sup, spec))] do
      ProcessRegistry.insert(hub.hub_id, spec, [{node(), pid}], metadata: meta)
    end

    :ok
  end

  defp started({:ok, pid, _info}), do: {:ok, pid}
  defp started(result), do: result
end
