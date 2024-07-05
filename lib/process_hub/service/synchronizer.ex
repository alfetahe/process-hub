defmodule ProcessHub.Service.Synchronizer do
  @moduledoc """
  The synchronizer service provides API functions for synchronizing process
  registry data between nodes.
  """

  alias ProcessHub.Handler.Synchronization
  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Utility.Name

  # TODO: add tests
  def exec_interval_sync(hub_id, strategy, sync_data, remote_node) do
    Task.Supervisor.async_nolink(
      Name.task_supervisor(hub_id),
      Synchronization.IntervalSyncHandle,
      :handle,
      [
        %Synchronization.IntervalSyncHandle{
          hub_id: hub_id,
          sync_strat: strategy,
          sync_data: sync_data,
          remote_node: remote_node
        }
      ]
    )
    |> Task.await()
  end

  @doc "Returns local node's process registry data used for synchronization."
  @spec local_sync_data(ProcessHub.hub_id()) :: [{ProcessHub.child_spec(), pid()}]
  def local_sync_data(hub_id) do
    ProcessRegistry.registry(hub_id)
    |> filter_local_data(hub_id)
  end

  @doc """
  Appends remote data to the local process registry.
  """
  @spec append_data(ProcessHub.hub_id(), %{node() => [{ProcessHub.child_spec(), pid()}]}) :: :ok
  def append_data(hub_id, remote_data) do
    table = Name.registry(hub_id)

    Enum.each(remote_data, fn {remote_node, remote_children} ->
      # TODO: may want to add some type of locking or transactions here.
      Enum.each(remote_children, fn {remote_cs, remote_pid} ->
        # Check if local children contain remote node data.
        case ProcessRegistry.lookup(hub_id, remote_cs.id, table: table) do
          nil ->
            # We don't have data locally so add it.
            ProcessRegistry.insert(hub_id, remote_cs, [{remote_node, remote_pid}], table: table)

          {_, local_child_nodes} ->
            {_current, updated} =
              Keyword.get_and_update(local_child_nodes, remote_node, fn current_value ->
                {current_value, remote_pid}
              end)

            # We have data locally, update the pid that is associated with the remote node.
            ProcessRegistry.insert(hub_id, remote_cs, updated, table: table)
        end
      end)
    end)
  end

  @doc """
  Detaches remote data from the local process registry.
  """
  @spec detach_data(ProcessHub.hub_id(), %{node() => [{ProcessHub.child_spec(), pid()}]}) :: :ok
  def detach_data(hub_id, remote_children) do
    local_registry = ProcessRegistry.registry(hub_id)

    Enum.each(local_registry, fn {child_id, {child_spec, child_nodes}} ->
      Enum.each(child_nodes, fn {child_node, _child_pid} ->
        if remote_children[child_node] do
          remote_child_spec =
            Enum.find(remote_children[child_node], fn {cs, _pid} -> cs.id == child_id end)

          unless remote_child_spec do
            new_child_nodes = Keyword.delete(child_nodes, child_node)

            if length(new_child_nodes) > 0 do
              ProcessRegistry.insert(hub_id, child_spec, new_child_nodes)
            else
              ProcessRegistry.delete(hub_id, child_spec.id)
            end
          end
        end
      end)
    end)
  end

  defp filter_local_data(process_registry, hub_id) do
    supervisor_child_ids =
      Name.distributed_supervisor(hub_id)
      |> DistributedSupervisor.local_child_ids()

    node = node()

    Enum.filter(process_registry, fn {child_id, _} ->
      Enum.member?(supervisor_child_ids, child_id)
    end)
    |> Enum.map(fn {_child_id, {child_spec, nodes}} ->
      child_pid = nodes[node]

      {child_spec, child_pid}
    end)
  end
end
