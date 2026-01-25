defmodule ProcessHub.Service.RequestTracker do
  @moduledoc """
  Service for tracking distributed request state.

  Provides common functionality for tracking request completion across nodes,
  used by both StartChildrenRequest and StopChildrenRequest.

  All functions work with any struct that has the required fields.
  """

  @doc """
  Checks if a request has expired based on its `expires_at` field.

  ## Parameters
    - `request` - Any struct with an `expires_at` field (monotonic milliseconds)

  ## Returns
    `true` if current time exceeds expires_at, `false` otherwise.
  """
  @spec expired?(map()) :: boolean()
  def expired?(%{expires_at: expires_at}) do
    System.monotonic_time(:millisecond) > expires_at
  end

  @doc """
  Checks if all expected nodes have responded.

  ## Parameters
    - `request` - Any struct with `nodes_data` and `completed_nodes` fields

  ## Returns
    `true` if all nodes in nodes_data are in completed_nodes.
  """
  @spec all_responded?(map()) :: boolean()
  def all_responded?(%{nodes_data: nodes_data, completed_nodes: completed}) do
    expected_nodes = nodes_data |> Enum.map(fn {node, _} -> node end) |> MapSet.new()
    MapSet.equal?(expected_nodes, completed)
  end

  @doc """
  Marks a node as having completed its response.

  ## Parameters
    - `request` - Any struct with a `completed_nodes` MapSet field
    - `node` - The node to mark as completed

  ## Returns
    Updated request with node added to completed_nodes.
  """
  @spec mark_completed(map(), node()) :: map()
  def mark_completed(%{completed_nodes: completed} = request, node) do
    %{request | completed_nodes: MapSet.put(completed, node)}
  end

  @doc """
  Sets the awaiter for a request.

  The awaiter is typically a GenServer `from` tuple that will receive
  the result when the request completes.

  ## Parameters
    - `request` - Any struct with an `awaiter` field
    - `from` - The GenServer from tuple `{pid, ref}`

  ## Returns
    Updated request with awaiter set.
  """
  @spec set_awaiter(map(), {pid(), reference()}) :: map()
  def set_awaiter(request, from) do
    %{request | awaiter: from}
  end

  @doc """
  Records a node's response and marks it as completed.

  Updates the sub_request for the given node with results and marks the node
  as completed.

  ## Parameters
    - `request` - Request struct with `sub_requests` list
    - `response_node` - The node that responded
    - `results` - The results from that node
    - `results_field` - Atom specifying which field to update (e.g., `:start_results` or `:stop_results`)

  ## Returns
    Updated request with results recorded and node marked completed.
  """
  @spec record_response(map(), node(), term(), atom()) :: map()
  def record_response(
        %{sub_requests: sub_requests} = request,
        response_node,
        results,
        results_field
      ) do
    updated_sub_requests =
      Enum.map(sub_requests, fn sub_req ->
        if sub_req.node == response_node do
          sub_req
          |> Map.put(results_field, results)
          |> Map.put(:status, :completed)
        else
          sub_req
        end
      end)

    request
    |> Map.put(:sub_requests, updated_sub_requests)
    |> mark_completed(response_node)
  end

  @doc """
  Calculates the expiry timestamp from a timeout value.

  ## Parameters
    - `timeout_ms` - Timeout in milliseconds

  ## Returns
    Monotonic time in milliseconds when the request expires.
  """
  @spec calculate_expiry(non_neg_integer()) :: integer()
  def calculate_expiry(timeout_ms) do
    System.monotonic_time(:millisecond) + timeout_ms
  end
end
