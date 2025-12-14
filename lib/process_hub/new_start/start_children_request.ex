defmodule ProcessHub.StartChildrenRequest do
  @moduledoc """
  Represents a request to start child processes across multiple nodes.

  This module encapsulates all the state and logic needed for tracking
  a distributed start children operation, including:
  - Composing and dispatching sub-requests to individual nodes
  - Recording node responses as they arrive
  - Building the final StartResult from aggregated responses
  """

  alias ProcessHub.Service.Dispatcher

  @default_request_timeout :timer.minutes(10)

  # Type for PostStartData from children_add.ex (used by build_node_response)
  @type post_start_data :: %{
          cid: ProcessHub.child_id(),
          result: term(),
          for_node: {node(), keyword()}
        }

  @type t() :: %__MODULE__{
          transaction_id: reference(),
          hub_id: ProcessHub.hub_id(),
          nodes_data: [{node(), [map()]}],
          child_specs: [ProcessHub.child_spec()],
          sub_requests: [NodeStartRequest.t()],
          future: ProcessHub.Future.t() | nil,
          options: keyword(),
          expires_at: integer(),
          awaiter: {pid(), reference()} | nil,
          completed_nodes: MapSet.t()
        }

  defstruct [
    :transaction_id,
    :hub_id,
    :expires_at,
    :awaiter,
    nodes_data: [],
    child_specs: [],
    sub_requests: [],
    future: nil,
    options: [],
    completed_nodes: MapSet.new()
  ]

  defmodule NodeStartRequest do
    @moduledoc """
    Represents a start request for a specific node, containing all data
    needed for the remote node to start children and route responses.
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
            # Additional options (disable_logging, etc.)
            options: keyword(),
            # Response tracking
            start_results: [{ProcessHub.child_id(), term()}] | nil,
            caller: pid() | nil,
            status: :pending | :dispatched | :completed
          }

    defstruct [
      :transaction_id,
      :hub_id,
      :originating_node,
      :reply_to,
      :node,
      :children,
      :start_results,
      :caller,
      options: [],
      status: :pending
    ]

    @doc """
    Converts NodeStartRequest to keyword options for backward compatibility
    with existing code that expects start_opts.
    """
    @spec to_start_opts(t()) :: keyword()
    def to_start_opts(%__MODULE__{} = req) do
      # Start with additional options (disable_logging, etc.)
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

  def new(hub, child_specs, mappings, opts) do
    transaction_id = make_ref()
    timeout = Keyword.get(opts, :request_timeout, @default_request_timeout)
    expires_at = System.monotonic_time(:millisecond) + timeout

    future = %ProcessHub.Future{
      future_resolver: {hub.hub_id, node()},
      timeout: Keyword.get(opts, :timeout, 5000),
      ref: transaction_id
    }

    %__MODULE__{
      transaction_id: transaction_id,
      hub_id: hub.hub_id,
      expires_at: expires_at,
      child_specs: child_specs,
      nodes_data: mappings,
      future: future,
      sub_requests: [],
      options: opts,
      awaiter: nil,
      completed_nodes: MapSet.new()
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

    # Pass through options that are needed on remote nodes (like disable_logging)
    # Filter out routing options that are already explicitly set
    passthrough_opts =
      Keyword.drop(opts, [:reply_to, :transaction_id, :hub_id, :originating_node])

    sub_requests =
      Enum.map(mappings, fn {target_node, children} ->
        %NodeStartRequest{
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

    # Dispatch using the new signature that accepts NodeStartRequest list
    Dispatcher.children_start(hub_id, sub_requests)

    {:ok, %{request | sub_requests: sub_requests}}
  end

  @doc """
  Records a node's response to the start children request.

  Updates the sub_request for the given node with the start results
  and marks the node as completed.

  ## Parameters
    - `request` - The StartChildrenRequest struct
    - `response_node` - The node that responded
    - `results` - List of `{child_id, result}` tuples from the node

  ## Returns
    Updated StartChildrenRequest struct with the node's results recorded.
  """
  @spec record_node_response(t(), node(), [{ProcessHub.child_id(), term()}]) :: t()
  def record_node_response(%__MODULE__{} = request, response_node, results) do
    updated_sub_requests =
      Enum.map(request.sub_requests, fn sub_req ->
        if sub_req.node == response_node do
          %{sub_req | start_results: results, status: :completed}
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
    - `request` - The StartChildrenRequest struct
    - `from` - The GenServer `from` tuple `{pid, ref}`

  ## Returns
    Updated StartChildrenRequest struct with the awaiter set.
  """
  @spec set_awaiter(t(), {pid(), reference()}) :: t()
  def set_awaiter(%__MODULE__{} = request, from) do
    %{request | awaiter: from}
  end

  @doc """
  Converts a completed request into a StartResult struct.

  Aggregates results from all sub_requests into a single StartResult,
  categorizing each child as either started successfully or errored.

  ## Parameters
    - `request` - The StartChildrenRequest struct

  ## Returns
    A `ProcessHub.StartResult` struct with:
    - `:status` - `:ok` if all children started, `:error` if any failed
    - `:started` - List of `{child_id, [{node, pid}]}` for successful starts
    - `:errors` - List of `{child_id, reason}` for failed starts
    - `:rollback` - Always `false` (rollback handled separately)
  """
  @spec to_start_result(t()) :: ProcessHub.StartResult.t()
  def to_start_result(%__MODULE__{} = request) do
    {started, errors} =
      Enum.reduce(request.sub_requests, {[], []}, fn sub_req, {started_acc, errors_acc} ->
        case sub_req.start_results do
          nil ->
            # Node didn't respond - treat as error
            child_errors =
              Enum.map(sub_req.children, fn child ->
                {Map.get(child, :child_id), {:error, :no_response}}
              end)

            {started_acc, errors_acc ++ child_errors}

          results ->
            # Process each result
            Enum.reduce(results, {started_acc, errors_acc}, fn {cid, result}, {s, e} ->
              case result do
                {:ok, pid} -> {[{cid, [{sub_req.node, pid}]} | s], e}
                {:error, reason} -> {s, [{cid, reason} | e]}
                pid when is_pid(pid) -> {[{cid, [{sub_req.node, pid}]} | s], e}
              end
            end)
        end
      end)

    status = if Enum.empty?(errors), do: :ok, else: :error

    %ProcessHub.StartResult{
      status: status,
      started: started,
      errors: errors,
      rollback: false
    }
  end

  ##############################################################################
  # Node-side response handling
  ##############################################################################

  @doc """
  Builds the response data to send back to the coordinator from PostStartData results.

  This is used by nodes that receive sub-requests to format their results
  before sending them back to the originating coordinator.

  ## Parameters
    - `post_start_results` - List of PostStartData structs from the node's child starts

  ## Returns
    List of `{child_id, result}` tuples for this node's children.
  """
  @spec build_node_response([post_start_data()]) :: [{ProcessHub.child_id(), term()}]
  def build_node_response(post_start_results) do
    local_node = node()

    post_start_results
    |> Enum.filter(fn %{for_node: {for_node, _}} -> for_node === local_node end)
    |> Enum.map(fn %{cid: cid, result: res} -> {cid, res} end)
  end

  @doc """
  Sends the node's start results back to the originating coordinator.

  This function extracts the transaction info from start_opts and sends
  a GenServer.cast to the coordinator on the originating node.

  ## Parameters
    - `start_opts` - Keyword list with `:hub_id`, `:transaction_id`, and `:originating_node`
    - `results` - List of `{child_id, result}` tuples from this node

  ## Returns
    - `:ok` if the response was sent
    - `:skip` if no transaction info was present (legacy mode)
  """
  @spec send_response_to_coordinator(keyword(), [{ProcessHub.child_id(), term()}]) :: :ok | :skip
  def send_response_to_coordinator(start_opts, results) do
    hub_id = Keyword.get(start_opts, :hub_id)
    transaction_id = Keyword.get(start_opts, :transaction_id)

    if hub_id && transaction_id do
      originating_node = Keyword.get(start_opts, :originating_node, node())
      local_node = node()

      GenServer.cast(
        {hub_id, originating_node},
        {:start_children_response, transaction_id, local_node, results}
      )

      :ok
    else
      :skip
    end
  end
end
