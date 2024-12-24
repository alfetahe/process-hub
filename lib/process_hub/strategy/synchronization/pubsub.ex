defmodule ProcessHub.Strategy.Synchronization.PubSub do
  @moduledoc """
  This PubSub synchronization strategy uses the `:blockade` library to
  dispatch and handle synchronization events. Each `ProcessHub` instance
  has its own event queue that is used to dispatch and handle synchronization events.
  """

  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Utility.Name
  alias ProcessHub.Service.Synchronizer
  alias ProcessHub.Constant.Event
  alias ProcessHub.Constant.PriorityLevel
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

    @impl true
    def init(_strategy, _hub_id), do: nil

    @impl SynchronizationStrategy
    def propagate(_strategy, hub_id, children, node, :add, opts) do
      Blockade.dispatch_sync(
        Name.event_queue(hub_id),
        @event_children_registration,
        {children, node, opts},
        %{
          priority: PriorityLevel.locked(),
          members: Keyword.get(opts, :members, :global)
        }
      )

      :ok
    end

    def propagate(_strategy, hub_id, children, node, :rem, opts) do
      Blockade.dispatch_sync(
        Name.event_queue(hub_id),
        @event_children_unregistration,
        {children, node, opts},
        %{
          priority: PriorityLevel.locked(),
          members: Keyword.get(opts, :members, :global)
        }
      )

      :ok
    end

    @impl SynchronizationStrategy
    def init_sync(strategy, hub_id, cluster_nodes) do
      local_data = Synchronizer.local_sync_data(hub_id)
      local_node = node()

      cluster_nodes
      |> Enum.filter(&(&1 !== local_node))
      |> Enum.each(fn node ->
        Node.spawn(node, fn ->
          GenServer.cast(
            Name.worker_queue(hub_id),
            {:handle_work,
             fn -> Synchronizer.exec_interval_sync(hub_id, strategy, local_data, local_node) end}
          )
        end)
      end)

      :ok
    end

    @impl SynchronizationStrategy
    def handle_synchronization(_strategy, hub_id, remote_data, remote_node) do
      Synchronizer.append_data(hub_id, %{remote_node => remote_data})
      Synchronizer.detach_data(hub_id, %{remote_node => remote_data})

      :ok
    end
  end
end
