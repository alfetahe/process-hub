defmodule ProcessHub.Service.RequestManager do
  @moduledoc """
  Unified module for distributed operation tracking and execution utilities.

  This module provides:
  - Operation struct for tracking distributed operations across nodes
  - State management (store, get, update, remove from coordinator state)
  - GenServer handlers for coordinator callbacks
  - Execution utilities (partition check, send response, request factories)
  - Tracking utilities (expired?, all_responded?, record_response)
  - Request splitting for batching large requests
  """

  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.State
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Request.Handler.StartChildrenRequest
  alias ProcessHub.Request.Handler.StopChildrenRequest
  alias ProcessHub.Request.Handler.PidsRegisterRequest
  alias ProcessHub.Request.Handler.PidsUnregisterRequest
  alias ProcessHub.Hub

  @max_children_per_request 1000
  @max_pids_per_request 10_000

  @default_timeout :timer.minutes(10)

  @type t :: %__MODULE__{
          transaction_id: reference(),
          hub_id: ProcessHub.hub_id(),
          handler: module(),
          nodes_data: [{node(), [map()]}],
          sub_requests: [struct()],
          completed_nodes: MapSet.t(),
          expires_at: integer(),
          awaiter: {pid(), reference()} | nil,
          future: ProcessHub.Future.t() | nil,
          options: keyword()
        }

  defstruct [
    :transaction_id,
    :hub_id,
    :handler,
    :nodes_data,
    :expires_at,
    :awaiter,
    :future,
    sub_requests: [],
    completed_nodes: MapSet.new(),
    options: []
  ]

  ##############################################################################
  # Constructor
  ##############################################################################

  @doc """
  Creates a new Operation struct.
  """
  @spec new(Hub.t(), module(), [{node(), [map()]}], keyword()) :: t()
  def new(hub, handler_module, nodes_data, opts) do
    timeout = Keyword.get(opts, :request_timeout, @default_timeout)
    future_timeout = Keyword.get(opts, :timeout, 5000)
    transaction_id = make_ref()

    future = %ProcessHub.Future{
      future_resolver: {hub.hub_id, node()},
      timeout: future_timeout,
      ref: transaction_id,
      action: handler_action(handler_module)
    }

    %__MODULE__{
      transaction_id: transaction_id,
      hub_id: hub.hub_id,
      handler: handler_module,
      nodes_data: nodes_data,
      expires_at: System.monotonic_time(:millisecond) + timeout,
      future: future,
      options: opts
    }
  end

  ##############################################################################
  # Operation functions
  ##############################################################################

  @doc """
  Composes sub-requests for each target node.
  """
  @spec compose_sub_requests(t()) :: {:ok, t()} | {:error, :no_children}
  def compose_sub_requests(%__MODULE__{nodes_data: []}), do: {:error, :no_children}

  def compose_sub_requests(%__MODULE__{handler: handler, nodes_data: nodes_data} = operation) do
    sub_requests =
      Enum.map(nodes_data, fn {target_node, children} ->
        handler.new(operation, target_node, children)
      end)

    {:ok, %{operation | sub_requests: sub_requests}}
  end

  @doc """
  Records a node's response and checks if operation is complete.
  """
  @spec process_response(t(), node(), term()) :: {:complete, t()} | {:pending, t()}
  def process_response(%__MODULE__{} = operation, response_node, results) do
    updated = record_response(operation, response_node, results, :results)

    if all_responded?(updated) do
      {:complete, updated}
    else
      {:pending, updated}
    end
  end

  @doc """
  Finalizes an operation by aggregating results and running post-processing.
  """
  @spec finalize(t(), Hub.t()) :: struct()
  def finalize(%__MODULE__{handler: handler} = operation, hub) do
    result = handler.aggregate_results(operation)
    handler.post_process(operation, result, hub)
  end

  ##############################################################################
  # State management (coordinator state)
  ##############################################################################

  @spec store(Hub.t(), t()) :: Hub.t()
  def store(state, %__MODULE__{} = operation) do
    pending = Map.put(state.pending_operations, operation.transaction_id, operation)
    %{state | pending_operations: pending}
  end

  @spec get(Hub.t(), reference()) :: t() | nil
  def get(state, transaction_id) do
    Map.get(state.pending_operations, transaction_id)
  end

  @spec update(Hub.t(), t()) :: Hub.t()
  def update(state, %__MODULE__{} = operation) do
    pending = Map.put(state.pending_operations, operation.transaction_id, operation)
    %{state | pending_operations: pending}
  end

  @spec remove(Hub.t(), reference()) :: Hub.t()
  def remove(state, transaction_id) do
    pending = Map.delete(state.pending_operations, transaction_id)
    %{state | pending_operations: pending}
  end

  @spec cleanup_expired(Hub.t()) :: Hub.t()
  def cleanup_expired(state) do
    pending =
      state.pending_operations
      |> Enum.reject(fn {_id, op} -> expired?(op) end)
      |> Map.new()

    %{state | pending_operations: pending}
  end

  ##############################################################################
  # GenServer handlers (called from Coordinator)
  ##############################################################################

  @spec handle_response(Hub.t(), reference(), node(), term()) :: {:noreply, Hub.t()}
  def handle_response(state, transaction_id, response_node, results) do
    case get(state, transaction_id) do
      nil ->
        {:noreply, state}

      operation ->
        case process_response(operation, response_node, results) do
          {:complete, updated} ->
            result = finalize(updated, state)
            if updated.awaiter, do: GenServer.reply(updated.awaiter, result)
            {:noreply, remove(state, transaction_id)}

          {:pending, updated} ->
            {:noreply, update(state, updated)}
        end
    end
  end

  @spec handle_await(Hub.t(), reference(), {pid(), reference()}) ::
          {:reply, term(), Hub.t()} | {:noreply, Hub.t()}
  def handle_await(state, transaction_id, from) do
    case get(state, transaction_id) do
      nil ->
        {:reply, {:error, :pending_request_not_found}, state}

      operation ->
        timeout = Keyword.get(operation.options, :timeout, 5000)

        cond do
          all_responded?(operation) ->
            {:reply, finalize(operation, state), remove(state, transaction_id)}

          timeout == 0 ->
            {:reply, finalize(operation, state), remove(state, transaction_id)}

          true ->
            updated = set_awaiter(operation, from)
            Process.send_after(self(), {:await_timeout, transaction_id, from}, timeout)
            {:noreply, update(state, updated)}
        end
    end
  end

  @spec handle_timeout(Hub.t(), reference(), {pid(), reference()}) :: {:noreply, Hub.t()}
  def handle_timeout(state, transaction_id, from) do
    case get(state, transaction_id) do
      nil ->
        {:noreply, state}

      operation ->
        if operation.awaiter == from do
          GenServer.reply(from, finalize(operation, state))
          {:noreply, remove(state, transaction_id)}
        else
          {:noreply, state}
        end
    end
  end

  ##############################################################################
  # Tracking utilities
  ##############################################################################

  @spec expired?(map()) :: boolean()
  def expired?(%{expires_at: expires_at}) do
    System.monotonic_time(:millisecond) > expires_at
  end

  @spec all_responded?(map()) :: boolean()
  def all_responded?(%{nodes_data: nodes_data, completed_nodes: completed}) do
    expected_nodes = nodes_data |> Enum.map(fn {node, _} -> node end) |> MapSet.new()
    MapSet.equal?(expected_nodes, completed)
  end

  @spec set_awaiter(map(), {pid(), reference()}) :: map()
  def set_awaiter(request, from) do
    %{request | awaiter: from}
  end

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

  defp mark_completed(%{completed_nodes: completed} = request, node) do
    %{request | completed_nodes: MapSet.put(completed, node)}
  end

  ##############################################################################
  # Execution utilities
  ##############################################################################

  @doc """
  Wraps function execution with partition check.
  """
  @spec with_partition_check(Hub.t(), (-> term())) :: term() | {:error, :partitioned}
  def with_partition_check(hub, fun) do
    case State.is_partitioned?(hub) do
      true -> {:error, :partitioned}
      false -> fun.()
    end
  end

  @doc """
  Loads the strategies a child-start request resolves against.

  Propagation reads the synchronization strategy itself, through
  `ProcessHub.Service.Dispatcher.propagate_event/3`.
  """
  @spec load_strategies(Hub.t()) :: %{dist: term(), redun: term()}
  def load_strategies(hub) do
    %{
      dist: Storage.get(hub.storage.misc, StorageKey.strdist()),
      redun: Storage.get(hub.storage.misc, StorageKey.strred())
    }
  end

  @doc """
  Sends response to coordinator.
  """
  @spec send_response(atom(), keyword(), [{ProcessHub.child_id(), term()}]) :: :ok | :skip
  def send_response(response_type, opts, results) do
    hub_id = Keyword.get(opts, :hub_id)
    transaction_id = Keyword.get(opts, :transaction_id)
    originating_node = Keyword.get(opts, :originating_node)

    if hub_id && transaction_id && originating_node do
      local_node = node()

      GenServer.cast(
        {hub_id, originating_node},
        {response_type, transaction_id, local_node, results}
      )

      :ok
    else
      :skip
    end
  end

  @doc """
  Converts request struct to keyword options for response routing.
  """
  @spec request_to_opts(map()) :: keyword()
  def request_to_opts(request) do
    opts = request.options || []

    opts =
      if request.transaction_id,
        do: [{:transaction_id, request.transaction_id} | opts],
        else: opts

    opts = if request.hub_id, do: [{:hub_id, request.hub_id} | opts], else: opts

    opts =
      if request.originating_node,
        do: [{:originating_node, request.originating_node} | opts],
        else: opts

    if request.reply_to, do: [{:reply_to, request.reply_to} | opts], else: opts
  end

  @doc """
  Factory: Creates a migration request for topology expansion.
  """
  @spec migration_request(Hub.t(), node(), [{ProcessHub.child_spec(), map()}], keyword()) ::
          StartChildrenRequest.t()
  def migration_request(hub, target_node, children_data, opts \\ []) do
    dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())
    request_signature = DistributionStrategy.distribution_signature(dist_strat, hub)
    post_action = Keyword.get(opts, :post_action)
    passthrough_opts = Keyword.drop(opts, [:post_action])

    children =
      Enum.map(children_data, fn {child_spec, metadata} ->
        %{
          child_id: child_spec.id,
          child_spec: child_spec,
          metadata: metadata,
          nodes: [target_node],
          migration: true
        }
      end)

    %StartChildrenRequest{
      transaction_id: make_ref(),
      request_signature: request_signature,
      hub_id: hub.hub_id,
      originating_node: nil,
      reply_to: nil,
      node: target_node,
      children: children,
      options: passthrough_opts,
      post_action: post_action
    }
  end

  @doc """
  Factory: Creates a contraction request for topology contraction.
  """
  @spec contraction_request(Hub.t(), [{ProcessHub.child_spec(), map()}], keyword()) ::
          StartChildrenRequest.t()
  def contraction_request(hub, children_data, opts \\ [migration_add: true]) do
    local_node = node()
    dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())
    request_signature = DistributionStrategy.distribution_signature(dist_strat, hub)

    children =
      Enum.map(children_data, fn {child_spec, metadata} ->
        %{
          child_id: child_spec.id,
          child_spec: child_spec,
          metadata: metadata,
          nodes: [local_node],
          migration: true
        }
      end)

    %StartChildrenRequest{
      transaction_id: make_ref(),
      request_signature: request_signature,
      hub_id: hub.hub_id,
      originating_node: nil,
      reply_to: nil,
      node: local_node,
      children: children,
      options: opts
    }
  end

  ##############################################################################
  # Forwarding utilities
  ##############################################################################

  @doc """
  Groups children by target node into a keyword list `[{node, [child_data, ...]}, ...]`.
  """
  @spec populate_forward(keyword(), [node()], map()) :: keyword()
  def populate_forward(forward_data, target_nodes, child_data) do
    Enum.reduce(target_nodes, forward_data, fn target_node, acc ->
      Keyword.update(acc, target_node, [child_data], &[child_data | &1])
    end)
  end

  ##############################################################################
  # Request splitting
  ##############################################################################

  @doc """
  Splits large requests into smaller batches for efficient cross-node transmission.
  """
  @spec split(struct()) :: [struct()]
  def split(%StartChildrenRequest{children: children} = req)
      when length(children) <= @max_children_per_request,
      do: [req]

  def split(%StartChildrenRequest{children: children} = req) do
    children
    |> Enum.chunk_every(@max_children_per_request)
    |> Enum.map(fn chunk -> %{req | children: chunk} end)
  end

  def split(%StopChildrenRequest{children: children} = req)
      when length(children) <= @max_children_per_request,
      do: [req]

  def split(%StopChildrenRequest{children: children} = req) do
    children
    |> Enum.chunk_every(@max_children_per_request)
    |> Enum.map(fn chunk -> %{req | children: chunk} end)
  end

  def split(%PidsRegisterRequest{children_data: data} = req)
      when map_size(data) <= @max_pids_per_request,
      do: [req]

  def split(%PidsRegisterRequest{children_data: data}) do
    data
    |> Map.to_list()
    |> Enum.chunk_every(@max_pids_per_request)
    |> Enum.map(fn chunk -> %PidsRegisterRequest{children_data: Map.new(chunk)} end)
  end

  def split(%PidsUnregisterRequest{removable_cid_nodes: data} = req)
      when length(data) <= @max_pids_per_request,
      do: [req]

  def split(%PidsUnregisterRequest{removable_cid_nodes: data} = req) do
    data
    |> Enum.chunk_every(@max_pids_per_request)
    |> Enum.map(fn chunk -> %{req | removable_cid_nodes: chunk} end)
  end

  def split(request), do: [request]

  ##############################################################################
  # Private
  ##############################################################################

  defp handler_action(handler_module) do
    module_name = handler_module |> Module.split() |> List.last()

    case module_name do
      "StartChildrenRequest" -> :start
      "StopChildrenRequest" -> :stop
      _ -> :unknown
    end
  end
end
