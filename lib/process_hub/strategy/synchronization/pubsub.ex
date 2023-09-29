defmodule ProcessHub.Strategy.Synchronization.PubSub do
  @moduledoc """
  This PubSub synchronization strategy uses the `:blockade` library to
  dispatch and handle synchronization events. Each `ProcessHub` instance
  has its own global event queue that is used to dispatch and handle synchronization events.
  """

  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Utility.Name
  alias ProcessHub.Service.Synchronizer
  alias ProcessHub.Constant.Event
  alias :blockade, as: Blockade

  @typedoc """
  The PubSub synchronization strategy options.

  - `sync_interval` - the periodic synchronization interval in milliseconds. Defaults to `15000`.
  """
  @type t :: %__MODULE__{
          sync_interval: pos_integer()
        }
  defstruct sync_interval: 15000

  defimpl SynchronizationStrategy, for: ProcessHub.Strategy.Synchronization.PubSub do
    use Event

    @spec propagate(
            ProcessHub.Strategy.Synchronization.PubSub.t(),
            ProcessHub.hub_id(),
            term(),
            node(),
            :add | :rem
          ) ::
            :ok
    def propagate(_strategy, hub_id, children, node, :add) do
      Blockade.dispatch_sync(
        Name.global_event_queue(hub_id),
        @event_children_registration,
        {children, node}
      )

      :ok
    end

    def propagate(_strategy, hub_id, child_ids, node, :rem) do
      Blockade.dispatch_sync(
        Name.global_event_queue(hub_id),
        @event_children_unregistration,
        {child_ids, node}
      )

      :ok
    end

    @spec handle_propagation(
            ProcessHub.Strategy.Synchronization.PubSub.t(),
            ProcessHub.hub_id(),
            term(),
            :rem | :add
          ) :: :ok
    def handle_propagation(_strategy, _hub_id, _propagation_data, _type), do: :ok

    @spec init_sync(ProcessHub.Strategy.Synchronization.PubSub.t(), ProcessHub.hub_id(), [node()]) ::
            :ok
    def init_sync(strategy, hub_id, cluster_nodes) do
      coordinator = Name.coordinator(hub_id)

      local_data = Synchronizer.local_sync_data(hub_id)
      local_node = node()

      cluster_nodes
      |> Enum.filter(&(&1 !== local_node))
      |> Enum.each(fn node ->
        Node.spawn(node, fn ->
          GenServer.cast(coordinator, {:handle_sync, strategy, local_data, local_node})
        end)
      end)

      :ok
    end

    @spec handle_synchronization(
            ProcessHub.Strategy.Synchronization.PubSub.t(),
            ProcessHub.hub_id(),
            term(),
            node()
          ) ::
            :ok
    def handle_synchronization(_strategy, hub_id, remote_data, remote_node) do
      Synchronizer.append_data(hub_id, %{remote_node => remote_data})
      Synchronizer.detach_data(hub_id, %{remote_node => remote_data})

      :ok
    end
  end
end
