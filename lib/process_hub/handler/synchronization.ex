defmodule ProcessHub.Handler.Synchronization do
  @moduledoc false

  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.State
  alias ProcessHub.Service.Storage
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Hub

  use Task

  defmodule IntervalSyncInit do
    @moduledoc """
    Handler for initializing synchronization.
    """
    alias ProcessHub.Service.Cluster

    @type t() :: %__MODULE__{
            hub: Hub.t()
          }

    @enforce_keys [
      :hub
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{hub: hub} = arg) do
      sync_strat = Storage.get(hub.storage.misc, StorageKey.strsyn())

      unless State.is_locked?(arg.hub.hub_id) do
        hub_nodes = Cluster.nodes(hub.storage.misc, [:include_local])

        SynchronizationStrategy.init_sync(sync_strat, hub.hub_id, hub_nodes)
      end

      :ok
    end
  end

  defmodule IntervalSyncHandle do
    @moduledoc """
    Handler for periodic synchronization.
    """

    @type t() :: %__MODULE__{
            hub: Hub.t(),
            sync_strat: SynchronizationStrategy.t(),
            sync_data: any(),
            remote_node: node()
          }

    @enforce_keys [
      :hub,
      :sync_strat,
      :sync_data,
      :remote_node
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = args) do
      SynchronizationStrategy.handle_synchronization(
        args.sync_strat,
        args.hub,
        args.sync_data,
        args.remote_node
      )
    end
  end

  defmodule ProcessEmitHandle do
    @moduledoc """
    Handler for emitting process registry data.
    """

    @type t() :: %__MODULE__{
            hub: Hub.t(),
            remote_children: [{ProcessHub.child_spec(), pid(), ProcessHub.child_metadata()}],
            remote_node: node()
          }

    @enforce_keys [
      :hub,
      :remote_node,
      :remote_children
    ]
    defstruct @enforce_keys

    def handle(%__MODULE__{} = args) do
      local_data = ProcessRegistry.dump(args.hub.hub_id)

      # Add all new processes to the local process table or update their nodes list.
      updated_data =
        Enum.reduce(args.remote_children, [], fn {child_spec, child_pid, metadata}, acc ->
          append_mismatches(
            Map.get(local_data, child_spec.id),
            {child_spec.id, {child_spec, [{args.remote_node, child_pid}], metadata}},
            acc
          )
        end)

      if length(updated_data) > 0 do
        ProcessRegistry.bulk_insert(args.hub.hub_id, Map.new(updated_data),
          hook_storage: args.hub.storage.hook
        )
      end
    end

    defp append_mismatches(nil, {child_id, {child_spec, child_nodes, metadata}}, data_list) do
      [{child_id, {child_spec, child_nodes, metadata}} | data_list]
    end

    defp append_mismatches(
           local_child_data,
           {child_id, {child_spec, child_nodes, metadata}},
           data_list
         ) do
      local_nodes = elem(local_child_data, 1) |> Enum.sort()

      remote_nodes =
        Enum.sort(child_nodes)
        |> Enum.reject(fn {_node, pid} ->
          pid === nil
        end)

      if local_nodes !== remote_nodes do
        combined_nodes = (local_nodes ++ remote_nodes) |> Enum.uniq()
        [{child_id, {child_spec, combined_nodes, metadata}} | data_list]
      else
        data_list
      end
    end
  end
end
