defmodule ProcessHub.Service.Dispatcher do
  @moduledoc """
  The dispatcher service provides API functions for dispatching events.
  """

  alias ProcessHub.Constant.PriorityLevel
  alias :blockade, as: Blockade
  alias ProcessHub.Utility.Name

  use ProcessHub.Constant.Event

  @doc """
  Sends a message to all the respondents who are waiting for a response.
  """
  @spec reply_respondents([pid()], atom(), ProcessHub.child_id(), term(), node()) :: :ok
  def reply_respondents(respondents, key, child_id, result, node) do
    Enum.each(respondents, fn respondent ->
      send(respondent, {key, child_id, result, node})
    end)
  end

  @doc """
  Sends the coordinator process a message to start the child processes passed in.

  @TODO: should use the underlying PubSub or Gossip.
  """
  @spec children_start(ProcessHub.hub_id(), [{node(), [map()]}], keyword()) :: :ok
  def children_start(hub_id, children_nodes, opts) do
    Enum.each(children_nodes, fn {child_node, children_data} ->
      GenServer.cast({hub_id, child_node}, {:start_children, children_data, opts})
    end)
  end

  @doc """
  Sends the coordinator process a message to start the child processes passed in.
  """
  @spec children_migrate(ProcessHub.hub_id(), [{node(), [map()]}], keyword()) :: :ok
  def children_migrate(hub_id, children_nodes, opts) do
    Enum.each(children_nodes, fn {child_node, children_data} ->
      Blockade.dispatch_sync(
        Name.event_queue(hub_id),
        @event_migration_add,
        {children_data, opts},
        %{
          members: [child_node],
          priority: PriorityLevel.locked()
        }
      )
    end)

    :ok
  end

  @doc """
  Sends the coordinator process a message to stop the child processes passed in.
  """
  @spec children_stop(ProcessHub.hub_id(), [{node(), [ProcessHub.child_id()]}], keyword()) :: :ok
  def children_stop(hub_id, children_nodes, stop_opts) do
    coordinator = hub_id

    Enum.each(children_nodes, fn {child_node, children} ->
      GenServer.cast({coordinator, child_node}, {:stop_children, children, stop_opts})
    end)
  end

  @doc """
  Propagates the event to the event queue.
  """
  @spec propagate_event(ProcessHub.hub_id(), atom(), term(), %{
          optional(:discard_event) => boolean,
          optional(:members) => :global | :local | :external | [node()],
          optional(:priority) => integer(),
          optional(:atomic_priority_set) => integer()
        }) :: {:ok, :event_discarded | :event_dispatched | :event_queued}
  def propagate_event(hub_id, event_id, event_data, opts \\ %{})

  def propagate_event(hub_id, event_id, event_data, opts) do
    Blockade.dispatch_sync(
      Name.event_queue(hub_id),
      event_id,
      event_data,
      opts
    )
  end
end
