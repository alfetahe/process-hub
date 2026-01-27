defmodule ProcessHub.Service.Dispatcher do
  @moduledoc """
  The dispatcher service provides API functions for dispatching events.
  """

  alias ProcessHub.Request.Handler.StartChildrenRequest.ChildStartRequest
  alias ProcessHub.Request.Handler.StopChildrenRequest.ChildStopRequest
  alias ProcessHub.Service.RequestSplitter
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
  Sends ChildStartRequest structs to their target coordinator processes.

  Each ChildStartRequest contains all routing information needed by the
  remote node to process the request and send responses back.
  """
  @spec children_start(ProcessHub.hub_id(), [ChildStartRequest.t()]) :: :ok
  def children_start(hub_id, node_start_requests) when is_list(node_start_requests) do
    node_start_requests
    |> Enum.group_by(fn %ChildStartRequest{node: node} -> node end)
    |> Enum.each(fn {target_node, requests} ->
      split_requests = Enum.flat_map(requests, &RequestSplitter.split/1)
      send({hub_id, target_node}, {@event_requests_handle, split_requests})
    end)
  end

  @doc """
  Sends ChildStopRequest structs to their target coordinator processes.

  Each ChildStopRequest contains all routing information needed by the
  remote node to process the request and send responses back.
  """
  @spec children_stop(ProcessHub.hub_id(), [ChildStopRequest.t()]) :: :ok
  def children_stop(hub_id, node_stop_requests) when is_list(node_stop_requests) do
    node_stop_requests
    |> Enum.group_by(fn %ChildStopRequest{node: node} -> node end)
    |> Enum.each(fn {target_node, requests} ->
      split_requests = Enum.flat_map(requests, &RequestSplitter.split/1)
      send({hub_id, target_node}, {@event_requests_handle, split_requests})
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
