defmodule ProcessHub.Handler.Synchronization do
  @moduledoc false

  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.State
  alias ProcessHub.Service.Storage
  alias ProcessHub.Utility.Name
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy

  use Task

  defmodule IntervalSyncInit do
    @moduledoc """
    Handler for initializing synchronization.
    """
    alias ProcessHub.Service.Cluster

    @type t() :: %__MODULE__{
            hub_id: ProcessHub.hub_id(),
            sync_strat: SynchronizationStrategy.t()
          }

    @enforce_keys [
      :hub_id
    ]
    defstruct @enforce_keys ++ [:sync_strat]

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = arg) do
      arg = %__MODULE__{
        arg
        | sync_strat: Storage.get(Name.local_storage(arg.hub_id), StorageKey.strsyn())
      }

      unless State.is_locked?(arg.hub_id) do
        hub_nodes = Cluster.nodes(arg.hub_id, [:include_local])

        SynchronizationStrategy.init_sync(arg.sync_strat, arg.hub_id, hub_nodes)
      end

      :ok
    end
  end

  defmodule IntervalSyncHandle do
    @moduledoc """
    Handler for periodic synchronization.
    """

    @type t() :: %__MODULE__{
            hub_id: ProcessHub.hub_id(),
            sync_strat: SynchronizationStrategy.t(),
            sync_data: any(),
            remote_node: node()
          }

    @enforce_keys [
      :hub_id,
      :sync_strat,
      :sync_data,
      :remote_node
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = args) do
      SynchronizationStrategy.handle_synchronization(
        args.sync_strat,
        args.hub_id,
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
            hub_id: ProcessHub.hub_id(),
            remote_children: [{ProcessHub.child_spec(), pid()}],
            remote_node: node()
          }

    @enforce_keys [
      :hub_id,
      :remote_node,
      :remote_children
    ]
    defstruct @enforce_keys

    def handle(%__MODULE__{} = args) do
      local_data = ProcessRegistry.registry(args.hub_id)

      # Add all new processes to the local process table or update their nodes list.
      updated_data =
        Enum.reduce(args.remote_children, [], fn {child_spec, child_pid}, acc ->
          append_mismatches(
            Map.get(local_data, child_spec.id),
            {child_spec.id, {child_spec, [{args.remote_node, child_pid}]}},
            acc
          )
        end)

      if length(updated_data) > 0 do
        ProcessRegistry.bulk_insert(args.hub_id, Map.new(updated_data))
      end
    end

    defp append_mismatches(nil, {child_id, {child_spec, child_nodes}}, data_list) do
      [{child_id, {child_spec, child_nodes}} | data_list]
    end

    defp append_mismatches(local_child_data, {child_id, {child_spec, child_nodes}}, data_list) do
      local_nodes = elem(local_child_data, 1) |> Enum.sort()

      remote_nodes =
        Enum.sort(child_nodes)
        |> Enum.reject(fn {_node, pid} ->
          pid === nil
        end)

      if local_nodes !== remote_nodes do
        combined_nodes = (local_nodes ++ remote_nodes) |> Enum.uniq()
        [{child_id, {child_spec, combined_nodes}} | data_list]
      else
        data_list
      end
    end
  end
end
