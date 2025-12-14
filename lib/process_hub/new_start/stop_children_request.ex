defmodule ProcessHub.StopChildrenRequest do
  @moduledoc """
  Represents a request to stop child processes across multiple nodes.

  This module encapsulates all the state and logic needed for tracking
  a distributed stop children operation, including:
  - Composing and dispatching sub-requests to individual nodes
  - Recording node responses as they arrive
  - Building the final StopResult from aggregated responses
  """

  alias ProcessHub.Service.Dispatcher

  @default_request_timeout :timer.minutes(10)

  @type t() :: %__MODULE__{
          transaction_id: reference(),
          hub_id: ProcessHub.hub_id(),
          nodes_data: [{node(), [map()]}],
          sub_requests: [NodeStopRequest.t()],
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

  defmodule NodeStopRequest do
    @moduledoc """
    Represents a stop request for a specific node, containing all data
    needed for the remote node to stop children and route responses.
    """

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
    Converts NodeStopRequest to keyword options for backward compatibility
    with existing code that expects stop_opts.
    """
    @spec to_stop_opts(t()) :: keyword()
    def to_stop_opts(%__MODULE__{} = req) do
      # Start with additional options
      opts = req.options || []

      # Add routing fields
      opts = if req.transaction_id, do: [{:transaction_id, req.transaction_id} | opts], else: opts
      opts = if req.hub_id, do: [{:hub_id, req.hub_id} | opts], else: opts

      opts =
        if req.originating_node,
          do: [{:originating_node, req.originating_node} | opts],
          else: opts

      opts = if req.reply_to, do: [{:reply_to, req.reply_to} | opts], else: opts
      opts
    end
  end

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
  def expired?(%__MODULE__{expires_at: expires_at}) do
    System.monotonic_time(:millisecond) > expires_at
  end

  @spec all_nodes_responded?(t()) :: boolean()
  def all_nodes_responded?(%__MODULE__{nodes_data: nodes_data, completed_nodes: completed}) do
    expected_nodes = Enum.map(nodes_data, fn {node, _} -> node end) |> MapSet.new()
    MapSet.equal?(expected_nodes, completed)
  end

  @spec mark_node_completed(t(), node()) :: t()
  def mark_node_completed(%__MODULE__{} = request, node) do
    %{request | completed_nodes: MapSet.put(request.completed_nodes, node)}
  end

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
        %NodeStopRequest{
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

  Updates the sub_request for the given node with the stop results
  and marks the node as completed.

  ## Parameters
    - `request` - The StopChildrenRequest struct
    - `response_node` - The node that responded
    - `results` - List of `{child_id, result}` tuples from the node

  ## Returns
    Updated StopChildrenRequest struct with the node's results recorded.
  """
  @spec record_node_response(t(), node(), [{ProcessHub.child_id(), term()}]) :: t()
  def record_node_response(%__MODULE__{} = request, response_node, results) do
    updated_sub_requests =
      Enum.map(request.sub_requests, fn sub_req ->
        if sub_req.node == response_node do
          %{sub_req | stop_results: results, status: :completed}
        else
          sub_req
        end
      end)

    request
    |> Map.put(:sub_requests, updated_sub_requests)
    |> mark_node_completed(response_node)
  end

  @doc """
  Sets the awaiter for this request.

  The awaiter is the GenServer `from` tuple that will receive the result
  when the request completes.

  ## Parameters
    - `request` - The StopChildrenRequest struct
    - `from` - The GenServer `from` tuple `{pid, ref}`

  ## Returns
    Updated StopChildrenRequest struct with the awaiter set.
  """
  @spec set_awaiter(t(), {pid(), reference()}) :: t()
  def set_awaiter(%__MODULE__{} = request, from) do
    %{request | awaiter: from}
  end

  @doc """
  Converts a completed request into a StopResult struct.

  Aggregates results from all sub_requests into a single StopResult,
  categorizing each child as either stopped successfully or errored.

  ## Parameters
    - `request` - The StopChildrenRequest struct

  ## Returns
    A `ProcessHub.StopResult` struct with:
    - `:status` - `:ok` if all children stopped, `:error` if any failed
    - `:stopped` - List of `{child_id, :ok}` for successful stops
    - `:errors` - List of `{child_id, reason}` for failed stops
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

  This is used by nodes that receive sub-requests to format their results
  before sending them back to the originating coordinator.

  ## Parameters
    - `post_stop_results` - List of `{child_id, result, node}` tuples from the node's child stops

  ## Returns
    List of `{child_id, result}` tuples for this node's children.
  """
  @spec build_node_response([{ProcessHub.child_id(), term(), node()}]) ::
          [{ProcessHub.child_id(), term()}]
  def build_node_response(post_stop_results) do
    local_node = node()

    post_stop_results
    |> Enum.filter(fn {_cid, _result, stop_node} -> stop_node === local_node end)
    |> Enum.map(fn {cid, result, _node} -> {cid, result} end)
  end

  @doc """
  Sends the node's stop results back to the originating coordinator.

  This function extracts the transaction info from stop_opts and sends
  a GenServer.cast to the coordinator on the originating node.

  ## Parameters
    - `stop_opts` - Keyword list with `:hub_id`, `:transaction_id`, and `:originating_node`
    - `results` - List of `{child_id, result}` tuples from this node

  ## Returns
    - `:ok` if the response was sent
    - `:skip` if no transaction info was present (legacy mode)
  """
  @spec send_response_to_coordinator(keyword(), [{ProcessHub.child_id(), term()}]) :: :ok | :skip
  def send_response_to_coordinator(stop_opts, results) do
    hub_id = Keyword.get(stop_opts, :hub_id)
    transaction_id = Keyword.get(stop_opts, :transaction_id)

    if hub_id && transaction_id do
      originating_node = Keyword.get(stop_opts, :originating_node, node())
      local_node = node()

      GenServer.cast(
        {hub_id, originating_node},
        {:stop_children_response, transaction_id, local_node, results}
      )

      :ok
    else
      :skip
    end
  end
end
