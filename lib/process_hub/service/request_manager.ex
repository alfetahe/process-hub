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
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Request.Handler.StartChildrenRequest
  alias ProcessHub.Request.Handler.StopChildrenRequest
  alias ProcessHub.Request.Handler.PidsRegisterRequest
  alias ProcessHub.Request.Handler.PidsUnregisterRequest
  alias ProcessHub.Coordinator.State
  alias ProcessHub.Hub

  @typedoc """
  Who answers a sub-request: the node, or the node and the nodes that
  forwarded the request to it.
  """
  @type responder() :: node() | {node(), [node()]}

  @max_children_per_request 1000
  @max_pids_per_request 10_000

  @default_timeout :timer.minutes(10)
  @result_retention_grace 1000

  @type t :: %__MODULE__{
          transaction_id: reference(),
          hub_id: ProcessHub.hub_id(),
          handler: module(),
          nodes_data: [{node(), [map()]}],
          sub_requests: [struct()],
          expires_at: integer(),
          awaiter: {pid(), reference()} | nil,
          future: ProcessHub.Future.t() | nil,
          result: struct() | nil,
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
    :result,
    sub_requests: [],
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
  @spec process_response(t(), responder(), term()) :: {:complete, t()} | {:pending, t()}
  def process_response(%__MODULE__{} = operation, responder, results) do
    updated = record_response(operation, responder, results, :results)

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

  @spec store(State.t(), t()) :: State.t()
  def store(state, %__MODULE__{} = operation) do
    pending = Map.put(state.pending_operations, operation.transaction_id, operation)
    %{state | pending_operations: pending}
  end

  @spec get(State.t(), reference()) :: t() | nil
  def get(state, transaction_id) do
    Map.get(state.pending_operations, transaction_id)
  end

  @spec update(State.t(), t()) :: State.t()
  def update(state, %__MODULE__{} = operation) do
    pending = Map.put(state.pending_operations, operation.transaction_id, operation)
    %{state | pending_operations: pending}
  end

  @spec remove(State.t(), reference()) :: State.t()
  def remove(state, transaction_id) do
    pending = Map.delete(state.pending_operations, transaction_id)
    %{state | pending_operations: pending}
  end

  @spec cleanup_expired(State.t()) :: State.t()
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

  @spec handle_response(State.t(), reference(), responder(), term()) ::
          {:noreply, State.t()}
  def handle_response(state, transaction_id, responder, results) do
    case get(state, transaction_id) do
      nil ->
        {:noreply, state}

      # A retained result is final; split chunks reply again under the same id.
      %__MODULE__{result: result} when result != nil ->
        {:noreply, state}

      operation ->
        case process_response(operation, responder, results) do
          {:complete, updated} ->
            result = finalize(updated, state.hub)

            cond do
              updated.awaiter ->
                GenServer.reply(updated.awaiter, result)
                {:noreply, remove(state, transaction_id)}

              Keyword.get(updated.options, :awaitable, false) ->
                # `await/1` is a separate round trip and may arrive after completion.
                {:noreply, update(state, retain_result(updated, result))}

              true ->
                {:noreply, remove(state, transaction_id)}
            end

          {:pending, updated} ->
            {:noreply, update(state, updated)}
        end
    end
  end

  @spec handle_await(State.t(), reference(), {pid(), reference()}) ::
          {:reply, term(), State.t()} | {:noreply, State.t()}
  def handle_await(state, transaction_id, from) do
    case get(state, transaction_id) do
      nil ->
        {:reply, {:error, :pending_request_not_found}, state}

      %__MODULE__{result: result} when result != nil ->
        {:reply, result, remove(state, transaction_id)}

      operation ->
        timeout = Keyword.get(operation.options, :timeout, 5000)

        cond do
          all_responded?(operation) or waits_only_on_departed?(operation) ->
            {:reply, finalize(operation, state.hub), remove(state, transaction_id)}

          timeout == 0 ->
            {:reply, finalize(operation, state.hub), remove(state, transaction_id)}

          true ->
            updated = set_awaiter(operation, from)
            Process.send_after(self(), {:await_timeout, transaction_id, from}, timeout)
            {:noreply, update(state, updated)}
        end
    end
  end

  @doc """
  Answers each awaited operation that now waits only on nodes this node is no
  longer connected to. Their children answer `:no_response` at once, as they
  would at the timeout, so a caller can try again while the time it was given
  lasts. Called when a node goes down.
  """
  @spec handle_departed(State.t()) :: State.t()
  def handle_departed(state) do
    Enum.reduce(state.pending_operations, state, fn {transaction_id, operation}, acc ->
      if operation.awaiter != nil and operation.result == nil and
           waits_only_on_departed?(operation) do
        GenServer.reply(operation.awaiter, finalize(operation, acc.hub))
        remove(acc, transaction_id)
      else
        acc
      end
    end)
  end

  defp waits_only_on_departed?(%{sub_requests: sub_requests}) do
    connected = [node() | Node.list()]
    waiting = for sub_req <- sub_requests, sub_req.status != :completed, do: sub_req.node
    waiting != [] and Enum.all?(waiting, &(&1 not in connected))
  end

  @spec handle_timeout(State.t(), reference(), {pid(), reference()}) ::
          {:noreply, State.t()}
  def handle_timeout(state, transaction_id, from) do
    case get(state, transaction_id) do
      nil ->
        {:noreply, state}

      operation ->
        if operation.awaiter == from do
          GenServer.reply(from, finalize(operation, state.hub))
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
  def all_responded?(%{sub_requests: sub_requests}) do
    Enum.all?(sub_requests, &(&1.status == :completed))
  end

  @spec set_awaiter(map(), {pid(), reference()}) :: map()
  def set_awaiter(request, from) do
    %{request | awaiter: from}
  end

  @doc """
  Records the answer of `responder` to its sub-request.

  An answer naming a child as `{:forwarded, node}` adds a sub-request for that
  node's answer to the forward. A forward's answer can arrive before the
  answer announcing it; it is kept, and the announcement then finds it.
  """
  @spec record_response(map(), responder(), term(), atom()) :: map()
  def record_response(%{sub_requests: sub_requests} = request, responder, results, results_field) do
    {node, path} = key = responder_key(responder)
    {forwards, results} = Enum.split_with(results, &match?({_, {:forwarded, _}}, &1))

    sub_requests =
      sub_requests
      |> expect_answer(request, key, [])
      |> Enum.map(fn sub_req ->
        if sub_key(sub_req) == key,
          do: sub_req |> Map.put(results_field, results) |> Map.put(:status, :completed),
          else: sub_req
      end)

    forwards
    |> Enum.group_by(fn {_cid, {:forwarded, target}} -> target end, &elem(&1, 0))
    |> Enum.reduce(sub_requests, fn {target, cids}, acc ->
      expect_answer(acc, request, {target, path ++ [node]}, cids)
    end)
    |> then(&%{request | sub_requests: &1})
  end

  defp expect_answer(sub_requests, request, {node, path} = key, cids) do
    if Enum.any?(sub_requests, &(sub_key(&1) == key)) do
      sub_requests
    else
      children = Enum.map(cids, &%{child_id: &1})
      opts = [forward_path: path]
      sub_requests ++ [struct(request.handler, node: node, children: children, options: opts)]
    end
  end

  defp sub_key(sub_req), do: {sub_req.node, forward_path(sub_req.options)}

  defp responder_key({node, path}), do: {node, path}
  defp responder_key(node), do: {node, []}

  ##############################################################################
  # Execution utilities
  ##############################################################################

  @doc """
  Wraps function execution with partition check.
  """
  @spec with_partition_check(Hub.t(), (-> term())) :: term() | {:error, :partitioned}
  def with_partition_check(hub, fun) do
    case ProcessHub.Service.State.is_partitioned?(hub) do
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
      responder =
        case forward_path(opts) do
          [] -> node()
          path -> {node(), path}
        end

      GenServer.cast(
        {hub_id, originating_node},
        {response_type, transaction_id, responder, results}
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

  Each child carries `migrated_from`, the node it is moving away from.
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
          migration: true,
          migrated_from: node()
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
  The nodes that forwarded the request whose options are `opts`, in order.
  """
  @spec forward_path(keyword()) :: [node()]
  def forward_path(opts), do: Keyword.get(opts, :forward_path, [])

  @doc """
  The fields of a request this node forwards on behalf of the request whose
  options are `opts`: the same transaction and originating node, so the
  target answers the coordinator that is waiting, and the forward path
  extended by this node, which names the answer and bounds the forwarding.
  """
  @spec forward_fields(Hub.t(), keyword()) :: map()
  def forward_fields(hub, opts) do
    passthrough = Keyword.drop(opts, [:reply_to, :transaction_id, :hub_id, :originating_node])

    %{
      transaction_id: Keyword.get(opts, :transaction_id),
      hub_id: hub.hub_id,
      originating_node: Keyword.get(opts, :originating_node),
      options: Keyword.put(passthrough, :forward_path, forward_path(opts) ++ [node()]),
      status: :dispatched
    }
  end

  @doc """
  True when every node a child belongs to already forwarded it, so forwarding
  it again would only send it back.
  """
  @spec forward_loop?([node()], [node()]) :: boolean()
  def forward_loop?(nodes, path), do: nodes != [] and Enum.all?(nodes, &(&1 in path))

  @doc """
  The answers a node gives for the children it forwarded, one
  `{child_id, {:forwarded, node}}` per target.
  """
  @spec forwarded_answers(keyword()) :: [{ProcessHub.child_id(), {:forwarded, node()}}]
  def forwarded_answers(forward_data) do
    for {target, children} <- forward_data,
        %{child_id: cid} <- children,
        do: {cid, {:forwarded, target}}
  end

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

  defp retain_result(%__MODULE__{} = operation, result) do
    retention = Keyword.get(operation.options, :timeout, 5000) + @result_retention_grace
    expires_at = System.monotonic_time(:millisecond) + retention
    %{operation | result: result, sub_requests: [], nodes_data: [], expires_at: expires_at}
  end

  defp handler_action(handler_module) do
    module_name = handler_module |> Module.split() |> List.last()

    case module_name do
      "StartChildrenRequest" -> :start
      "StopChildrenRequest" -> :stop
      _ -> :unknown
    end
  end
end
