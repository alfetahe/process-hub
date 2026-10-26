defmodule ProcessHub.Service.Dispatcher do
  @moduledoc """
  The dispatcher service provides API functions for dispatching events.
  """

  alias ProcessHub.Request.Handler.StartChildrenRequest
  alias ProcessHub.Request.Handler.StopChildrenRequest
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.RequestManager
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias :blockade, as: Blockade

  @async_queue_limit 10_000

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
  remote node to process the request and send responses back. Options are
  those of `send_requests/4`.
  """
  @spec children_start(ProcessHub.Hub.t(), [StartChildrenRequest.t()], keyword()) :: :ok
  def children_start(hub, node_start_requests, opts \\ []) when is_list(node_start_requests) do
    node_start_requests
    |> Enum.group_by(fn %StartChildrenRequest{node: node} -> node end)
    |> Enum.each(fn {target_node, requests} ->
      requests = Enum.flat_map(requests, &RequestManager.split/1)
      send_requests(hub, requests, [target_node], opts)
    end)

    track_starts(hub, node_start_requests)
  end

  @doc """
  Sends requests to the worker queues of `members` over the channel every
  request travels, so on each node they run after every request sent there
  before them from this node.

  ## Options
    - `:async` - when `true`, hands the requests to the event queue without
      waiting (`dispatch_event_async/4`), for the coordinator's own paths.
      Defaults to `false`.
  """
  @spec send_requests(
          ProcessHub.Hub.t(),
          [struct()],
          :global | :local | :external | [node()],
          keyword()
        ) :: :ok
  def send_requests(hub, requests, members, opts \\ []) do
    dispatch =
      if Keyword.get(opts, :async, false), do: &dispatch_event_async/4, else: &dispatch_event/4

    dispatch.(hub.procs.event_queue, @event_requests_handle, requests, %{members: members})
    :ok
  end

  # The registry only learns where a child runs once that node has started it.
  # Until then this node remembers where it sent the start, so a stop issued
  # meanwhile can still find the child. Written after the start is handed to the
  # event queue, so a stop forwarded from here is queued, and sent, behind it.
  @start_ttl 30_000

  defp track_starts(hub, requests) do
    requests
    |> Enum.flat_map(fn %StartChildrenRequest{node: node, children: children} ->
      Enum.map(children, &{&1.child_spec.id, node})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {cid, nodes} -> {{StorageKey.sif(), cid}, nodes, [ttl: @start_ttl]} end)
    |> then(&Storage.insert_many(hub.storage.misc, &1))

    :ok
  end

  @doc """
  Returns the nodes this node recently sent a start for `child_id` to, and
  forgets them, so the same stop is not forwarded twice. A target that has
  since left the cluster is dropped: a stop sent there is never answered, and
  the child it may have started went with it.
  """
  @spec take_start_targets(ProcessHub.Hub.t(), ProcessHub.child_id()) :: [node()]
  def take_start_targets(hub, child_id) do
    key = {StorageKey.sif(), child_id}
    targets = Storage.get(hub.storage.misc, key) || []
    if targets !== [], do: Storage.remove(hub.storage.misc, key)
    members = Cluster.nodes(hub.storage.misc, [:include_local])
    Enum.filter(targets, &(&1 in members))
  end

  @doc """
  Sends StopChildrenRequest structs to their target coordinator processes.

  Each StopChildrenRequest contains all routing information needed by the
  remote node to process the request and send responses back. Options are
  those of `send_requests/4`.
  """
  @spec children_stop(ProcessHub.Hub.t(), [StopChildrenRequest.t()], keyword()) :: :ok
  def children_stop(hub, node_stop_requests, opts \\ []) when is_list(node_stop_requests) do
    node_stop_requests
    |> Enum.group_by(fn %StopChildrenRequest{node: node} -> node end)
    |> Enum.each(fn {target_node, requests} ->
      requests = Enum.flat_map(requests, &RequestManager.split/1)
      send_requests(hub, requests, [target_node], opts)
    end)
  end

  @doc """
  Propagates a request to cluster members via the synchronization strategy.

  ## Options
    - `:members` - Target members (`:global`, `:local`, `:external`, or `[node()]`). Defaults to `:global`.
    - `:async` - see `send_requests/4`. Defaults to `false`.
  """
  @spec propagate_event(ProcessHub.Hub.t(), struct(), keyword()) :: :ok
  def propagate_event(hub, request, opts \\ []) do
    sync_strategy = Storage.get(hub.storage.misc, StorageKey.strsyn())

    SynchronizationStrategy.propagate(
      sync_strategy,
      hub,
      RequestManager.split(request),
      Keyword.put_new(opts, :members, :global)
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

  @doc """
  Dispatches an event to the event queue without waiting for it.

  The event queue sends to every member in turn, so a peer whose connection
  has stopped draining holds it until the connection recovers or drops. The
  coordinator uses this for its own events so it never waits on such a peer.
  Events sent from one process keep their order, also relative to the ones it
  sends with `dispatch_event/4`.

  The queue is bounded: past #{@async_queue_limit} waiting events the sender
  waits for it as with `dispatch_event/4`, so a stalled peer slows the sender
  down instead of growing the queue without limit. The wait ends after the
  queue's own call timeout; the event stays queued.
  """
  @spec dispatch_event_async(atom(), atom(), term(), %{
          optional(:discard_event) => boolean,
          optional(:members) => :global | :local | :external | [node()]
        }) :: :ok
  def dispatch_event_async(event_queue, event_id, event_data, opts \\ %{}) do
    if queue_len(event_queue) > @async_queue_limit do
      try do
        dispatch_event(event_queue, event_id, event_data, opts)
      catch
        :exit, {:timeout, _} -> :ok
      end

      :ok
    else
      Blockade.dispatch(event_queue, event_id, event_data, opts)
    end
  end

  defp queue_len(event_queue) do
    with pid when is_pid(pid) <- Process.whereis(event_queue),
         {:message_queue_len, len} <- Process.info(pid, :message_queue_len) do
      len
    else
      _ -> 0
    end
  end
end
