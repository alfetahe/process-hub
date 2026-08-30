defmodule ProcessHub.Task.SynchronizationTask do
  @moduledoc false

  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.State
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.Synchronizer
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

      if not State.is_partitioned?(arg.hub) and
           Synchronizer.broadcastable_local_data(hub) !== :suppress do
        hub_nodes = Cluster.nodes(hub.storage.misc, [:include_local])

        SynchronizationStrategy.init_sync(sync_strat, hub, hub_nodes)
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
end
