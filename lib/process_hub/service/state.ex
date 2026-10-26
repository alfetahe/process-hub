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
      Supervisor.terminate_child(hub.procs.initializer, :dist_sup)
      withdrawn = Cluster.purge_node(hub.hub_id, node())

      held = Storage.get(hub.storage.misc, StorageKey.plh()) || MapSet.new()

      Storage.insert(
        hub.storage.misc,
        StorageKey.plh(),
        MapSet.union(held, MapSet.new(withdrawn))
      )

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

  # A node still in partition mode holds rows as stale as this one's and
  # sends none; a node that does not answer adds nothing. A node that answers
  # speaks for itself: what the others still list it as running may be a child
  # it has just moved away and they have not yet heard of.
  defp merge_from_quorum(hub) do
    peers = Cluster.nodes(hub.storage.misc, [:connected])

    answers =
      for {peer, {:ok, rows}} <-
            Enum.zip(
              peers,
              :erpc.multicall(peers, __MODULE__, :quorum_rows, [hub.hub_id], @peer_call_ms)
            ),
          do: {peer, rows}

    answered = MapSet.new([node() | Enum.map(answers, &elem(&1, 0))])

    observed =
      for {peer, rows} <- answers,
          {_child_id, {spec, node_pids, meta}} <- rows,
          {node, pid} <- node_pids,
          node === peer or not MapSet.member?(answered, node),
          reduce: %{} do
        acc -> Map.update(acc, node, [{spec, pid, meta}], &[{spec, pid, meta} | &1])
      end

    Synchronizer.append_data(hub, observed)
  end

  @doc false
  def quorum_rows(hub_id) do
    if ProcessHub.is_partitioned?(hub_id), do: %{}, else: ProcessRegistry.dump_all(hub_id)
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
