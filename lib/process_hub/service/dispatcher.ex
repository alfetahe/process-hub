defmodule ProcessHub.Service.Dispatcher do
  @moduledoc """
  The dispatcher service provides API functions for dispatching events.
  """

  alias ProcessHub.Constant.PriorityLevel
  alias ProcessHub.StartChildrenRequest.NodeStartRequest
  alias ProcessHub.StopChildrenRequest.NodeStopRequest
  alias :blockade, as: Blockade

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
  Sends NodeStartRequest structs to their target coordinator processes.

  Each NodeStartRequest contains all routing information needed by the
  remote node to process the request and send responses back.
  """
  @spec children_start(ProcessHub.hub_id(), [NodeStartRequest.t()]) :: :ok
  def children_start(hub_id, node_start_requests) when is_list(node_start_requests) do
    Enum.each(node_start_requests, fn %NodeStartRequest{node: target_node} = request ->
      GenServer.cast({hub_id, target_node}, {:start_children, request})
    end)
  end

  @doc """
  Legacy: Sends coordinator processes messages to start child processes.

  @deprecated Use children_start/2 with NodeStartRequest list instead.
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
  @spec children_migrate(reference(), [{node(), [map()]}], keyword()) :: :ok
  def children_migrate(event_queue, children_nodes, opts) do
    Enum.each(children_nodes, fn {child_node, children_data} ->
      Blockade.dispatch_sync(
        event_queue,
        @event_migration_add,
        {children_data, opts},
        %{
          members: [child_node],
          priority: PriorityLevel.high()
        }
      )
    end)

    :ok
  end

  @doc """
  Sends NodeStopRequest structs to their target coordinator processes.

  Each NodeStopRequest contains all routing information needed by the
  remote node to process the request and send responses back.
  """
  @spec children_stop(ProcessHub.hub_id(), [NodeStopRequest.t()]) :: :ok
  def children_stop(hub_id, node_stop_requests) when is_list(node_stop_requests) do
    Enum.each(node_stop_requests, fn %NodeStopRequest{node: target_node} = request ->
      GenServer.cast({hub_id, target_node}, {:stop_children, request})
    end)
  end

  @doc """
  Legacy: Sends the coordinator process a message to stop the child processes passed in.

  @deprecated Use children_stop/2 with NodeStopRequest list instead.
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
  @spec propagate_event(atom(), atom(), term(), %{
          optional(:discard_event) => boolean,
          optional(:members) => :global | :local | :external | [node()],
          optional(:priority) => integer(),
          optional(:atomic_priority_set) => integer()
        }) :: {:ok, :event_discarded | :event_dispatched | :event_queued}
  def propagate_event(event_queue, event_id, event_data, opts \\ %{})

  def propagate_event(event_queue, event_id, event_data, opts) do
    Blockade.dispatch_sync(
      event_queue,
      event_id,
      event_data,
      opts
    )
  end
end
