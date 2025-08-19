defmodule ProcessHub.Service.Synchronizer do
  @moduledoc """
  The synchronizer service provides API functions for synchronizing process
  registry data between nodes.
  """

  alias ProcessHub.Coordinator
  alias ProcessHub.Handler.Synchronization
  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Hub

  # TODO: add tests
  @doc """
  Helper function to trigger interval synchronization.

  The system will use the configured synchronization strategy.
  """
  def trigger_sync(hub_state) do
    Task.Supervisor.async(
      hub_state.managers.task_supervisor,
      Synchronization.IntervalSyncInit,
      :handle,
      [
        %Synchronization.IntervalSyncInit{
          hub: hub_state
        }
      ]
    )
    |> Task.await()
  end

  # TODO: add tests
  def exec_interval_sync(hub_id, strategy, sync_data, remote_node) do
    hub = Coordinator.get_hub(hub_id)

    Task.Supervisor.async_nolink(
      hub.managers.task_supervisor,
      Synchronization.IntervalSyncHandle,
      :handle,
      [
        %Synchronization.IntervalSyncHandle{
          hub: hub,
          sync_strat: strategy,
          sync_data: sync_data,
          remote_node: remote_node
        }
      ]
    )
    |> Task.await()
  end

  @doc "Returns local node's process registry data used for synchronization."
  @spec local_sync_data(Hub.t()) :: [
          {ProcessHub.child_spec(), pid(), ProcessHub.child_metadata()}
        ]
  def local_sync_data(hub) do
    ProcessRegistry.dump(hub.hub_id)
    |> filter_local_data(hub.managers.distributed_supervisor)
  end

  @doc """
  Appends remote data to the local process registry.
  """
  @spec append_data(Hub.t(), %{
          node() => [{ProcessHub.child_spec(), pid(), ProcessHub.child_metadata()}]
        }) :: :ok
  def append_data(hub, remote_data) do
    Enum.each(remote_data, fn {remote_node, remote_children} ->
      # TODO: may want to add some type of locking or transactions here.
      Enum.each(remote_children, fn {remote_cs, remote_pid, remote_meta} ->
        # Check if local children contain remote node data.
        case ProcessRegistry.lookup(hub.hub_id, remote_cs.id) do
          nil ->
            # We don't have data locally so add it.
            ProcessRegistry.insert(
              hub.hub_id,
              remote_cs,
              [{remote_node, remote_pid}],
              hook_storage: hub.storage.hook,
              metadata: remote_meta
            )

          {_, local_child_nodes} ->
            {_current, updated} =
              Keyword.get_and_update(local_child_nodes, remote_node, fn current_value ->
                {current_value, remote_pid}
              end)

            # We have data locally, update the pid that is associated with the remote node.
            ProcessRegistry.insert(
              hub.hub_id,
              remote_cs,
              updated,
              hook_storage: hub.storage.hook,
              metadata: remote_meta
            )
        end
      end)
    end)
  end

  @doc """
  Detaches remote data from the local process registry.
  """
  @spec detach_data(Hub.t(), %{node() => [{ProcessHub.child_spec(), pid()}]}) :: :ok
  def detach_data(hub, remote_children) do
    local_registry = ProcessRegistry.dump(hub.hub_id)

    Enum.each(local_registry, fn {child_id, {child_spec, child_nodes, metadata}} ->
      opts = [metadata: metadata, hook_storage: hub.storage.hook]

      Enum.each(child_nodes, fn {child_node, _child_pid} ->
        if remote_children[child_node] do
          remote_child_spec =
            Enum.find(remote_children[child_node], fn {cs, _pid, _m} -> cs.id == child_id end)

          unless remote_child_spec do
            new_child_nodes = Keyword.delete(child_nodes, child_node)

            if length(new_child_nodes) > 0 do
              ProcessRegistry.insert(hub.hub_id, child_spec, new_child_nodes, opts)
            else
              ProcessRegistry.delete(hub.hub_id, child_spec.id, opts)
            end
          end
        end
      end)
    end)
  end

  defp filter_local_data(process_registry, dist_sup) do
    supervisor_child_ids = DistributedSupervisor.local_child_ids(dist_sup)
    node = node()

    Enum.filter(process_registry, fn {child_id, _} ->
      Enum.member?(supervisor_child_ids, child_id)
    end)
    |> Enum.map(fn {_child_id, {child_spec, nodes, metadata}} ->
      child_pid = nodes[node]

      {child_spec, child_pid, metadata}
    end)
  end
end
