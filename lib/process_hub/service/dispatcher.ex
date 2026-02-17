defmodule ProcessHub.Service.Dispatcher do
  @moduledoc """
  The dispatcher service provides API functions for dispatching events.
  """

  alias ProcessHub.Request.Handler.StartChildrenRequest
  alias ProcessHub.Request.Handler.StopChildrenRequest
  alias ProcessHub.Service.RequestManager
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
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
  Sends StartChildrenRequest structs to their target coordinator processes.

  Each StartChildrenRequest contains all routing information needed by the
  remote node to process the request and send responses back.
  """
  @spec children_start(ProcessHub.Hub.t(), [StartChildrenRequest.t()]) :: :ok
  def children_start(hub, node_start_requests) when is_list(node_start_requests) do
    node_start_requests
    |> Enum.group_by(fn %StartChildrenRequest{node: node} -> node end)
    |> Enum.each(fn {target_node, requests} ->
      split_requests = Enum.flat_map(requests, &RequestManager.split/1)

      Blockade.dispatch_sync(hub.procs.event_queue, @event_requests_handle, split_requests, %{
        members: [target_node]
      })
    end)
  end

  @doc """
  Sends StopChildrenRequest structs to their target coordinator processes.

  Each StopChildrenRequest contains all routing information needed by the
  remote node to process the request and send responses back.
  """
  @spec children_stop(ProcessHub.Hub.t(), [StopChildrenRequest.t()]) :: :ok
  def children_stop(hub, node_stop_requests) when is_list(node_stop_requests) do
    node_stop_requests
    |> Enum.group_by(fn %StopChildrenRequest{node: node} -> node end)
    |> Enum.each(fn {target_node, requests} ->
      split_requests = Enum.flat_map(requests, &RequestManager.split/1)

      Blockade.dispatch_sync(hub.procs.event_queue, @event_requests_handle, split_requests, %{
        members: [target_node]
      })
    end)
  end

  @doc """
  Propagates a request to cluster members via the synchronization strategy.

  ## Options
    - `:members` - Target members (`:global`, `:local`, `:external`, or `[node()]`). Defaults to `:global`.
  """
  @spec propagate_event(ProcessHub.Hub.t(), struct(), keyword()) :: :ok
  def propagate_event(hub, request, opts \\ []) do
    sync_strategy = Storage.get(hub.storage.misc, StorageKey.strsyn())
    members = Keyword.get(opts, :members, :global)

    SynchronizationStrategy.propagate(
      sync_strategy,
      hub,
      RequestManager.split(request),
      members: members
    )
  end

  @doc """
  Dispatches an event to the event queue.
  """
  @spec dispatch_event(atom(), atom(), term(), %{
          optional(:discard_event) => boolean,
          optional(:members) => :global | :local | :external | [node()]
        }) :: {:ok, :event_discarded | :event_dispatched | :event_queued}
  def dispatch_event(event_queue, event_id, event_data, opts \\ %{})

  def dispatch_event(event_queue, event_id, event_data, opts) do
    Blockade.dispatch_sync(
      event_queue,
      event_id,
      event_data,
      opts
    )
  end
end
