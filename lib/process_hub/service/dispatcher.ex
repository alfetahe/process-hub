defmodule ProcessHub.Service.Dispatcher do
  @moduledoc """
  The dispatcher service provides API functions for dispatching events.
  """

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
  """
  @spec children_start(ProcessHub.hub_id(), [{node(), [map()]}], keyword()) :: :ok
  def children_start(hub_id, children_nodes, opts) do
    coordinator = Name.coordinator(hub_id)

    Enum.each(children_nodes, fn {child_node, children_data} ->
      Node.spawn(child_node, fn ->
        GenServer.cast(coordinator, {:start_children, children_data, opts})
      end)
    end)
  end

  @doc """
  Sends the coordinator process a message to start the child processes passed in.
  """
  @spec children_migrate(ProcessHub.hub_id(), [{node(), [map()]}], keyword()) :: :ok
  def children_migrate(hub_id, children_nodes, opts) do
    Enum.each(children_nodes, fn {child_node, children_data} ->
      Node.spawn(child_node, fn ->
        Blockade.dispatch_sync(
          Name.local_event_queue(hub_id),
          @event_migration_add,
          {children_data, opts},
          %{members: [child_node]}
        )
      end)
    end)

    :ok
  end

  @doc """
  Sends the coordinator process a message to stop the child processes passed in.
  """
  @spec children_stop(ProcessHub.hub_id(), [{node(), [ProcessHub.child_id()]}]) :: :ok
  def children_stop(hub_id, children_nodes) do
    coordinator = Name.coordinator(hub_id)

    Enum.each(children_nodes, fn {child_node, children} ->
      Node.spawn(child_node, fn ->
        GenServer.cast(coordinator, {:stop_children, children})
      end)
    end)
  end

  @doc """
  Propagates the event to the local or global event queue.
  """
  @spec propagate_event(any, atom, any, :global | :local, %{
          optional(:discard_event) => boolean,
          optional(:members) => :global | :local | :external | [node()],
          optional(:priority) => integer(),
          optional(:atomic_priority_set) => integer()
        }) :: {:ok, :event_discarded | :event_dispatched | :event_queued}
  def propagate_event(hub_id, event_id, event_data, scope, opts \\ %{})

  def propagate_event(hub_id, event_id, event_data, :global, opts) do
    Blockade.dispatch_sync(
      Name.global_event_queue(hub_id),
      event_id,
      event_data,
      opts
    )
  end

  def propagate_event(hub_id, event_id, event_data, :local, opts) do
    Blockade.dispatch_sync(
      Name.local_event_queue(hub_id),
      event_id,
      event_data,
      opts
    )
  end
end
