defmodule ProcessHub.Request.Handler.StopChildrenRequest do
  @moduledoc """
  Represents a request to stop child processes across multiple nodes.

  This module encapsulates all the state and logic needed for tracking
  a distributed stop children operation, including:
  - Composing and dispatching sub-requests to individual nodes
  - Recording node responses as they arrive
  - Building the final StopResult from aggregated responses
  """

  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.RequestTracker

  @default_request_timeout :timer.minutes(10)

  @type t() :: %__MODULE__{
          transaction_id: reference(),
          hub_id: ProcessHub.hub_id(),
          nodes_data: [{node(), [map()]}],
          sub_requests: [ChildStopRequest.t()],
          future: ProcessHub.Future.t() | nil,
          options: keyword(),
          expires_at: integer(),
          awaiter: {pid(), reference()} | nil,
          completed_nodes: MapSet.t(),
          not_found_children: [ProcessHub.child_id()]
        }

  defstruct [
    :transaction_id,
    :hub_id,
    :expires_at,
    :awaiter,
    nodes_data: [],
    sub_requests: [],
    future: nil,
    options: [],
    completed_nodes: MapSet.new(),
    not_found_children: []
  ]

  defmodule ChildStopRequest do
    @moduledoc """
    Represents a request to stop children on a specific target node.

    Contains all data needed for the remote node to stop children
    and route responses back to the coordinator.

    Implements `ProcessHub.Request.CrossNodeRequest` protocol for execution
    on the target node.
    """

    alias ProcessHub.Service.Distributor
    alias ProcessHub.Service.RequestExecutor
    alias ProcessHub.Constant.StorageKey
    alias ProcessHub.Service.Storage
    alias ProcessHub.Request.Handler.StopChildrenRequest
    alias ProcessHub.Hub

    @type t() :: %__MODULE__{
            # Routing fields
            transaction_id: reference() | nil,
            hub_id: ProcessHub.hub_id() | nil,
            originating_node: node() | nil,
            reply_to: [pid()] | nil,
            # Child data
            node: node(),
            children: [map()],
            # Additional options
            options: keyword(),
            # Response tracking
            stop_results: [{ProcessHub.child_id(), term()}] | nil,
            status: :pending | :dispatched | :completed
          }

    defstruct [
      :transaction_id,
      :hub_id,
      :originating_node,
      :reply_to,
      :node,
      :children,
      :stop_results,
      options: [],
      status: :pending
    ]

    @doc """
    Converts ChildStopRequest to keyword options for backward compatibility
    with existing code that expects stop_opts.
    """
    @spec to_stop_opts(t()) :: keyword()
    def to_stop_opts(%__MODULE__{} = req), do: RequestExecutor.child_request_to_opts(req)

    @doc """
    Executes the stop request on the target node.

    This consolidates the logic previously in ChildrenRem.StopHandle.handle/1.
    """
    @spec execute(t(), Hub.t()) :: :ok | {:error, :partitioned}
    def execute(%__MODULE__{} = request, hub) do
      RequestExecutor.with_partition_check(hub, fn ->
        sync_strategy = Storage.get(hub.storage.misc, StorageKey.strsyn())

        # Extract child IDs
        cids =
          Enum.reduce(request.children, [], fn child_data, cids ->
            [child_data.child_id | cids]
          end)

        # Terminate children
        Distributor.children_terminate(hub, cids, sync_strategy)

        # Build and send response
        results = StopChildrenRequest.build_node_response(request.children)
        stop_opts = to_stop_opts(request)

        RequestExecutor.send_response(
          :stop_children_response,
          stop_opts,
          results
        )

        :ok
      end)
    end
  end

  ##############################################################################
  # Request tracking functions
  ##############################################################################

  def new(hub, nodes_data, opts, not_found_children \\ []) do
    transaction_id = make_ref()
    timeout = Keyword.get(opts, :request_timeout, @default_request_timeout)
    expires_at = System.monotonic_time(:millisecond) + timeout

    future = %ProcessHub.Future{
      future_resolver: {hub.hub_id, node()},
      timeout: Keyword.get(opts, :timeout, 5000),
      ref: transaction_id,
      action: :stop
    }

    %__MODULE__{
      transaction_id: transaction_id,
      hub_id: hub.hub_id,
      expires_at: expires_at,
      nodes_data: nodes_data,
      future: future,
      sub_requests: [],
      options: opts,
      awaiter: nil,
      completed_nodes: MapSet.new(),
      not_found_children: not_found_children
    }
  end

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{} = request), do: RequestTracker.expired?(request)

  @spec all_nodes_responded?(t()) :: boolean()
  def all_nodes_responded?(%__MODULE__{} = request), do: RequestTracker.all_responded?(request)

  @spec mark_node_completed(t(), node()) :: t()
  def mark_node_completed(%__MODULE__{} = request, node),
    do: RequestTracker.mark_completed(request, node)

  @spec compose_sub_requests(t()) :: {:ok, t()} | {:error, :no_children}
  def compose_sub_requests(%__MODULE__{nodes_data: []} = _request) do
    {:error, :no_children}
  end

  def compose_sub_requests(
        %__MODULE__{hub_id: hub_id, nodes_data: mappings, options: opts, transaction_id: tid} =
          request
      ) do
    originating = node()
    reply_to = Keyword.get(opts, :reply_to)

    # Pass through options that are needed on remote nodes
    # Filter out routing options that are already explicitly set
    passthrough_opts =
      Keyword.drop(opts, [:reply_to, :transaction_id, :hub_id, :originating_node])

    sub_requests =
      Enum.map(mappings, fn {target_node, children} ->
        %ChildStopRequest{
          transaction_id: tid,
          hub_id: hub_id,
          originating_node: originating,
          reply_to: reply_to,
          node: target_node,
          children: children,
          options: passthrough_opts,
          status: :dispatched
        }
      end)

    # Dispatch using the new signature that accepts NodeStopRequest list
    Dispatcher.children_stop(hub_id, sub_requests)

    {:ok, %{request | sub_requests: sub_requests}}
  end

  @doc """
  Records a node's response to the stop children request.
  """
  @spec record_node_response(t(), node(), [{ProcessHub.child_id(), term()}]) :: t()
  def record_node_response(%__MODULE__{} = request, response_node, results) do
    RequestTracker.record_response(request, response_node, results, :stop_results)
  end

  @doc """
  Sets the awaiter for this request.
  """
  @spec set_awaiter(t(), {pid(), reference()}) :: t()
  def set_awaiter(%__MODULE__{} = request, from), do: RequestTracker.set_awaiter(request, from)

  @doc """
  Converts a completed request into a StopResult struct.
  """
  @spec to_stop_result(t()) :: ProcessHub.StopResult.t()
  def to_stop_result(%__MODULE__{} = request) do
    {stopped, errors} =
      Enum.reduce(request.sub_requests, {[], []}, fn sub_req, {stopped_acc, errors_acc} ->
        case sub_req.stop_results do
          nil ->
            # Node didn't respond - treat as error
            child_errors =
              Enum.map(sub_req.children, fn child ->
                {Map.get(child, :child_id), {:error, :no_response}}
              end)

            {stopped_acc, errors_acc ++ child_errors}

          results ->
            # Process each result
            # StopResult expects stopped format: [{child_id, [nodes]}]
            Enum.reduce(results, {stopped_acc, errors_acc}, fn {cid, result}, {s, e} ->
              case result do
                :ok -> {[{cid, [sub_req.node]} | s], e}
                {:error, reason} -> {s, [{cid, reason} | e]}
                error -> {s, [{cid, error} | e]}
              end
            end)
        end
      end)

    # Add not_found_children as errors
    not_found_errors =
      Enum.map(request.not_found_children, fn cid ->
        {cid, {:error, :not_found}}
      end)

    all_errors = errors ++ not_found_errors
    status = if Enum.empty?(all_errors), do: :ok, else: :error

    %ProcessHub.StopResult{
      status: status,
      stopped: stopped,
      errors: all_errors
    }
  end

  ##############################################################################
  # Node-side response handling
  ##############################################################################

  @doc """
  Builds the response data to send back to the coordinator from post_stop_results.

  This function handles multiple input formats for flexibility:
  - List of maps with `:child_id` key (from NodeStopRequest.children)
  - List of `{child_id, result, node}` tuples (legacy format)
  """
  @spec build_node_response([map() | {ProcessHub.child_id(), term(), node()}]) ::
          [{ProcessHub.child_id(), term()}]
  def build_node_response(post_stop_results) do
    local_node = node()

    post_stop_results
    |> Enum.filter(fn
      # Map format from NodeStopRequest.children
      %{child_id: _cid} -> true
      # Tuple format (legacy)
      {_cid, _result, stop_node} -> stop_node === local_node
    end)
    |> Enum.map(fn
      # Map format - result is :ok since we're building response after successful termination
      %{child_id: cid} -> {cid, :ok}
      # Tuple format (legacy)
      {cid, result, _node} -> {cid, result}
    end)
  end
end

##############################################################################
# CrossNodeRequest protocol implementation
##############################################################################

defimpl ProcessHub.Request.CrossNodeRequest,
  for: ProcessHub.Request.Handler.StopChildrenRequest.ChildStopRequest do
  alias ProcessHub.Request.Handler.StopChildrenRequest.ChildStopRequest

  def handle(request, hub) do
    ChildStopRequest.execute(request, hub)
  end
end
