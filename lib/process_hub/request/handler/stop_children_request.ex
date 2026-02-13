defmodule ProcessHub.Request.Handler.StopChildrenRequest do
  @moduledoc """
  Node-level request for stopping child processes.

  This module represents a request to stop children on a specific target node.
  It implements the `CrossNodeRequest` protocol for execution on target nodes.

  ## Structure

  The request contains:
  - Routing fields (transaction_id, hub_id, originating_node, reply_to)
  - Target node and children data
  - Response tracking (stop_results)

  ## Usage

  Requests are typically created via `new/3` from an Operation,
  then dispatched to target nodes where `execute/2` runs the actual stop logic.
  """

  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.RequestManager
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.RequestManager
  alias ProcessHub.Constant.StorageKey
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
          results: [{ProcessHub.child_id(), term()}] | nil,
          status: :pending | :dispatched | :completed
        }

  defstruct [
    :transaction_id,
    :hub_id,
    :originating_node,
    :reply_to,
    :node,
    :children,
    :results,
    options: [],
    status: :pending
  ]

  ##############################################################################
  # Constructor and request handling
  ##############################################################################

  @doc """
  Creates a new StopChildrenRequest for a specific target node.

  Called by `RequestManager.compose_sub_requests/1` for each node in the operation's
  `nodes_data`. The returned struct contains all information needed to
  execute the request on the target node.

  ## Parameters
    - `operation` - The Operation struct containing common operation data
    - `target_node` - The node this request will be sent to
    - `children` - List of child data maps for this node

  ## Returns
    A new StopChildrenRequest struct.
  """
  @spec new(RequestManager.t(), node(), [map()]) :: t()
  def new(%RequestManager{} = operation, target_node, children) do
    passthrough_opts =
      Keyword.drop(operation.options, [:reply_to, :transaction_id, :hub_id, :originating_node])

    %__MODULE__{
      transaction_id: operation.transaction_id,
      hub_id: operation.hub_id,
      originating_node: node(),
      reply_to: Keyword.get(operation.options, :reply_to),
      node: target_node,
      children: children,
      options: passthrough_opts,
      status: :dispatched
    }
  end

  @doc """
  Execute the request on the target node.

  This function is invoked on the target node when the request arrives.
  It performs the actual work (stopping children) and sends a response
  back to the coordinator.

  ## Parameters
    - `request` - The StopChildrenRequest struct
    - `hub` - The Hub struct on the target node

  ## Returns
    - `:ok` on success
    - `{:error, :partitioned}` if the node is partitioned
  """
  @spec execute(t(), Hub.t()) :: :ok | {:error, :partitioned}
  def execute(%__MODULE__{} = request, hub) do
    RequestManager.with_partition_check(hub, fn ->
      sync_strategy = Storage.get(hub.storage.misc, StorageKey.strsyn())

      # Extract child IDs
      cids =
        Enum.reduce(request.children, [], fn child_data, cids ->
          [child_data.child_id | cids]
        end)

      # Terminate children
      Distributor.children_terminate(hub, cids, sync_strategy)

      # Build and send response
      results = build_node_response(request.children)
      stop_opts = to_stop_opts(request)

      RequestManager.send_response(
        :operation_response,
        stop_opts,
        results
      )

      :ok
    end)
  end

  @doc """
  Aggregates results from all sub-requests into a final StopResult.

  Called when all nodes have responded (or the operation has timed out).
  Collects results from all sub-requests and produces a single result struct.

  ## Parameters
    - `operation` - The completed Operation struct with all sub-request results

  ## Returns
    A `ProcessHub.StopResult` struct with aggregated results.
  """
  @spec aggregate_results(RequestManager.t()) :: ProcessHub.StopResult.t()
  def aggregate_results(%RequestManager{} = operation) do
    # Get not_found_children from options if present
    not_found_children = Keyword.get(operation.options, :not_found_children, [])

    {stopped, errors} =
      Enum.reduce(operation.sub_requests, {[], []}, fn sub_req, {stopped_acc, errors_acc} ->
        case sub_req.results do
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
      Enum.map(not_found_children, fn cid ->
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

  @doc """
  Returns the response message type for routing.

  This atom is used by the coordinator to route responses to the correct
  handler. Matches the message type sent by `RequestManager.send_response/3`.

  ## Returns
    The atom `:operation_response`.
  """
  @spec response_type() :: atom()
  def response_type, do: :operation_response

  @doc """
  Post-processes the aggregated result.

  For stop operations, no post-processing is needed - the result is returned unchanged.

  ## Parameters
    - `_operation` - The completed Operation struct (unused)
    - `result` - The aggregated StopResult
    - `_hub` - The Hub struct for context (unused)

  ## Returns
    The StopResult unchanged.
  """
  @spec post_process(RequestManager.t(), ProcessHub.StopResult.t(), Hub.t()) ::
          ProcessHub.StopResult.t()
  def post_process(_operation, result, _hub), do: result

  ##############################################################################
  # Public API
  ##############################################################################

  @doc """
  Converts StopChildrenRequest to keyword options for backward compatibility.
  """
  @spec to_stop_opts(t()) :: keyword()
  def to_stop_opts(%__MODULE__{} = req), do: RequestManager.request_to_opts(req)

  @doc """
  Builds the response data to send back to the coordinator from post_stop_results.

  Accepts a list of maps with `:child_id` key (from children).
  """
  @spec build_node_response([map()]) :: [{ProcessHub.child_id(), term()}]
  def build_node_response(post_stop_results) do
    post_stop_results
    |> Enum.filter(fn
      # Map format from children
      %{child_id: _cid} -> true
    end)
    |> Enum.map(fn
      # Map format - result is :ok since we're building response after successful termination
      %{child_id: cid} -> {cid, :ok}
    end)
  end
end

##############################################################################
# CrossNodeRequest protocol implementation
##############################################################################

defimpl ProcessHub.Request.CrossNodeRequest,
  for: ProcessHub.Request.Handler.StopChildrenRequest do
  alias ProcessHub.Request.Handler.StopChildrenRequest

  def handle(request, hub) do
    StopChildrenRequest.execute(request, hub)
  end
end
