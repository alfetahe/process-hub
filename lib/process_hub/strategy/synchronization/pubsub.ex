defmodule ProcessHub.Strategy.Synchronization.PubSub do
  @moduledoc """
  This PubSub synchronization strategy uses the `:blockade` library to
  dispatch and handle synchronization events. Each `ProcessHub` instance
  has its own event queue that is used to dispatch and handle synchronization events.
  """

  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Service.Synchronizer
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.Event
  alias ProcessHub.Constant.PriorityLevel
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Hub
  alias :blockade, as: Blockade

  @typedoc """
  The PubSub synchronization strategy options.

  - `sync_interval` - the periodic synchronization interval in milliseconds. Defaults to `30000`.
  """
  @type t :: %__MODULE__{
          sync_interval: pos_integer()
        }
  defstruct sync_interval: 30000

  defimpl SynchronizationStrategy, for: ProcessHub.Strategy.Synchronization.PubSub do
    use Event

    @impl true
    def init(strategy, _hub_id), do: strategy

    @impl SynchronizationStrategy
    def propagate(_strategy, %Hub{} = hub, requests, opts) when is_list(requests) do
      Blockade.dispatch_sync(
        hub.procs.event_queue,
        @event_requests_handle,
        requests,
        %{
          priority: Keyword.get(opts, :priority, PriorityLevel.high()),
          members: Keyword.get(opts, :members, :global)
        }
      )

      :ok
    end

    @impl SynchronizationStrategy
    def init_sync(strategy, %Hub{} = hub, cluster_nodes) do
      local_data = Synchronizer.local_sync_data(hub)

      local_node = node()

      cluster_nodes
      |> Enum.filter(&(&1 !== local_node))
      |> Enum.each(fn node ->
        Node.spawn(node, fn ->
          GenServer.cast(
            hub.procs.worker_queue,
            {
              :handle_work,
              fn ->
                Synchronizer.exec_interval_sync(hub.hub_id, strategy, local_data, local_node)
              end
            }
          )
        end)
      end)

      :ok
    end

    @impl SynchronizationStrategy
    def handle_synchronization(_strategy, hub, remote_data, remote_node) do
      Synchronizer.append_data(hub, %{remote_node => remote_data})
      Synchronizer.detach_data(hub, %{remote_node => remote_data})

      :ok
    end

    @impl SynchronizationStrategy
    def broadcast_local_data(_strategy, hub, local_data, target_nodes) do
      local_node = node()
      timestamp = Bag.timestamp(:microsecond)
      sync_data = {local_data, timestamp}

      Blockade.dispatch_sync(
        hub.procs.event_queue,
        @event_node_registry_broadcast,
        {sync_data, local_node},
        %{
          members: target_nodes
        }
      )

      :ok
    end

    @impl SynchronizationStrategy
    def handle_node_join_data(_strategy, hub, {remote_data, timestamp}, remote_node) do
      # Check timestamp against stored timestamp for this node
      node_timestamps = Storage.get(hub.storage.misc, StorageKey.gct()) || %{}
      stored_timestamp = Map.get(node_timestamps, remote_node)

      if stored_timestamp == nil or timestamp > stored_timestamp do
        Synchronizer.append_data(hub, %{remote_node => remote_data})

        # Update timestamp
        updated_timestamps = Map.put(node_timestamps, remote_node, timestamp)
        Storage.insert(hub.storage.misc, StorageKey.gct(), updated_timestamps)
      end

      :ok
    end
  end
end
