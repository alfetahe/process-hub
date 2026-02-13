defmodule ProcessHub.Request.Handler.StartChildrenRequest do
  @moduledoc """
  Node-level request for starting child processes.

  This module represents a request to start children on a specific target node.
  It implements the `CrossNodeRequest` protocol for execution on target nodes.

  ## Structure

  The request contains:
  - Routing fields (transaction_id, hub_id, originating_node, reply_to)
  - Target node and children data
  - Operation-specific fields (request_signature)
  - Response tracking (start_results)

  ## Usage

  Requests are typically created via `new/3` from an Operation,
  then dispatched to target nodes where `execute/2` runs the actual start logic.
  """

  alias ProcessHub.Service.LoggerService
  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.RequestManager
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Request.PostAction
  alias ProcessHub.Hub

  # TTL for pending registry entries (10 minutes)
  @pending_ttl_ms :timer.minutes(10)

  @type t() :: %__MODULE__{
          # Routing fields
          transaction_id: reference() | nil,
          request_signature: non_neg_integer() | nil,
          hub_id: ProcessHub.hub_id() | nil,
          originating_node: node() | nil,
          reply_to: [pid()] | nil,
          # Child data
          node: node(),
          children: [
            %{
              child_spec: ProcessHub.child_spec(),
              metadata: ProcessHub.child_metadata()
            }
          ],
          # Additional options (disable_logging, etc.)
          options: keyword(),
          # Response tracking
          results: [{ProcessHub.child_id(), term()}] | nil,
          status: :pending | :dispatched | :completed,
          # Post-action to execute after children are started
          post_action: ProcessHub.Request.PostAction.t() | nil
        }

  defstruct [
    :transaction_id,
    :request_signature,
    :hub_id,
    :originating_node,
    :reply_to,
    :node,
    :children,
    :results,
    :post_action,
    options: [],
    status: :pending
  ]

  ##############################################################################
  # CrossNodeRequest protocol implementation
  ##############################################################################

  defimpl ProcessHub.Request.CrossNodeRequest,
    for: ProcessHub.Request.Handler.StartChildrenRequest do
    alias ProcessHub.Request.Handler.StartChildrenRequest

    def handle(request, hub) do
      StartChildrenRequest.execute(request, hub)
    end
  end

  ##############################################################################
  # Helper structs
  ##############################################################################

  defmodule PostStartData do
    @moduledoc """
    Data structure for post-start processing results.
    """

    @type t :: %__MODULE__{
            cid: ProcessHub.child_id(),
            pid: pid(),
            child_spec: ProcessHub.child_spec(),
            result: {:ok, pid()} | {:error, term()},
            child_nodes: [{node(), pid()}],
            nodes: [node()],
            has_errors: boolean(),
            metadata: map(),
            for_node: node()
          }

    defstruct [
      :cid,
      :pid,
      :child_spec,
      :result,
      :for_node,
      :child_nodes,
      :has_errors,
      :nodes,
      metadata: %{}
    ]
  end

  ##############################################################################
  # Constructor and request handling
  ##############################################################################

  @doc """
  Creates a new StartChildrenRequest for a specific target node.

  Called by `RequestManager.compose_sub_requests/1` for each node in the operation's
  `nodes_data`. The returned struct contains all information needed to
  execute the request on the target node.

  ## Parameters
    - `operation` - The Operation struct containing common operation data
    - `target_node` - The node this request will be sent to
    - `children` - List of child data maps for this node

  ## Returns
    A new StartChildrenRequest struct.
  """
  @spec new(RequestManager.t(), node(), [map()]) :: t()
  def new(%RequestManager{} = operation, target_node, children) do
    passthrough_opts =
      Keyword.drop(operation.options, [:reply_to, :transaction_id, :hub_id, :originating_node])

    %__MODULE__{
      transaction_id: operation.transaction_id,
      request_signature: Keyword.get(operation.options, :request_signature),
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
  It performs the actual work (starting children) and sends a response
  back to the coordinator.

  ## Parameters
    - `request` - The StartChildrenRequest struct
    - `hub` - The Hub struct on the target node

  ## Returns
    - `:ok` on success
    - `{:error, :partitioned}` if the node is partitioned
  """
  @spec execute(t(), Hub.t()) :: :ok | {:error, :partitioned}
  def execute(%__MODULE__{} = request, hub) do
    RequestManager.with_partition_check(hub, fn ->
      strategies = RequestManager.load_strategies(hub)
      start_opts = to_start_opts(request)

      # Validate and start children
      validated_children = validate_children(request, hub, strategies)

      # Dispatch pre-start hook
      HookManager.dispatch_hook(hub.storage.hook, Hook.pre_children_start(), %{
        request: request,
        hub: hub
      })

      # Start children locally
      post_start_results = start_children(hub, validated_children, start_opts)

      # Dispatch post-start hook
      dispatch_post_start_hook(hub, post_start_results)

      # Dispatch process startups hook
      HookManager.dispatch_hook(hub.storage.hook, Hook.process_startups(), post_start_results)

      # Update local registry and send response
      update_registry(hub, post_start_results)

      # Build and send response
      send_response(post_start_results, start_opts)

      # Sync propagate to other nodes
      sync_propagate(hub, post_start_results, strategies.sync)

      # Execute post-action if present
      if request.post_action do
        execute_post_action(request.post_action, hub, post_start_results)
      end

      :ok
    end)
  end

  @doc """
  Aggregates results from all sub-requests into a final StartResult.

  Called when all nodes have responded (or the operation has timed out).
  Collects results from all sub-requests and produces a single result struct.

  ## Parameters
    - `operation` - The completed Operation struct with all sub-request results

  ## Returns
    A `ProcessHub.StartResult` struct with aggregated results.
  """
  @spec aggregate_results(RequestManager.t()) :: ProcessHub.StartResult.t()
  def aggregate_results(%RequestManager{} = operation) do
    {started, errors} =
      operation.sub_requests
      |> Enum.flat_map(&collect_sub_request_results/1)
      |> Enum.reduce({[], []}, fn result_tuple, {started_acc, errors_acc} ->
        case result_tuple do
          {:started, cid, node, pid} ->
            {[{cid, [{node, pid}]} | started_acc], errors_acc}

          {:error, cid, reason} ->
            {started_acc, [{cid, reason} | errors_acc]}
        end
      end)

    %ProcessHub.StartResult{
      status: if(Enum.empty?(errors), do: :ok, else: :error),
      started: started,
      errors: errors,
      rollback: false
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

  Handles rollback logic when `on_failure: :rollback` is set and the operation
  had errors. For successful operations or when `on_failure: :continue`, returns
  the result unchanged.

  ## Parameters
    - `operation` - The completed Operation struct
    - `result` - The aggregated StartResult
    - `hub` - The Hub struct for context

  ## Returns
    The StartResult, potentially modified with rollback flag if rollback was performed.
  """
  @spec post_process(RequestManager.t(), ProcessHub.StartResult.t(), Hub.t()) ::
          ProcessHub.StartResult.t()
  def post_process(operation, result, hub) do
    on_failure = Keyword.get(operation.options, :on_failure, :continue)

    if on_failure == :rollback and result.status == :error do
      perform_rollback(hub, result)
    else
      result
    end
  end

  # Performs rollback by stopping all successfully started children
  # Called when on_failure: :rollback is set and some children failed to start
  defp perform_rollback(hub, start_result) do
    alias ProcessHub.DistributedSupervisor

    # Extract successfully started child IDs
    success_cids = Enum.map(start_result.started, fn {cid, _nodes} -> cid end)

    if length(success_cids) > 0 do
      # For rollback, we need synchronous cleanup. Instead of going through
      # the async sync strategy, we directly:
      # 1. Terminate each child process
      # 2. Remove from registry directly
      Enum.each(success_cids, fn cid ->
        # Terminate the child process
        DistributedSupervisor.terminate_child(hub.procs.dist_sup, cid)
        # Directly remove from registry (synchronous)
        ProcessRegistry.delete(hub.hub_id, cid)
      end)
    end

    # Return result with rollback flag set
    %{start_result | rollback: true}
  end

  ##############################################################################
  # Public API
  ##############################################################################

  @doc """
  Converts StartChildrenRequest to keyword options for backward compatibility.
  """
  @spec to_start_opts(t()) :: keyword()
  def to_start_opts(%__MODULE__{} = req), do: RequestManager.request_to_opts(req)

  @doc """
  Factory: Creates a migration request for topology expansion.

  ## Options
    - `:post_action` - Optional `PostAction` to execute after children are started
  """
  @spec for_migration(Hub.t(), node(), [{ProcessHub.child_spec(), map()}], keyword()) :: t()
  def for_migration(hub, target_node, children_data, opts \\ []) do
    RequestManager.migration_request(hub, target_node, children_data, opts)
  end

  @doc """
  Factory: Creates a contraction request for ColdSwap topology contraction.
  """
  @spec for_contraction(Hub.t(), [{ProcessHub.child_spec(), map()}]) :: t()
  def for_contraction(hub, children_data) do
    RequestManager.contraction_request(hub, children_data)
  end

  @doc """
  Converts post-start results to storage format for registry insertion.
  """
  @spec store_format([PostStartData.t()]) :: map()
  def store_format(post_start_results) do
    for %PostStartData{has_errors: false, cid: cid, child_spec: cs, child_nodes: cn, metadata: m} <-
          post_start_results,
        into: %{},
        do: {cid, {cs, cn, m}}
  end

  @doc """
  Builds the response data to send back to the coordinator from PostStartData results.
  """
  @spec build_node_response([PostStartData.t()]) :: [{ProcessHub.child_id(), term()}]
  def build_node_response(post_start_results) do
    local = node()

    for %PostStartData{cid: cid, result: res, for_node: ^local} <- post_start_results,
        do: {cid, res}
  end

  @doc false
  def build_request(
        hub_id,
        transaction_id,
        request_signature,
        originating_node,
        reply_to,
        target_node,
        children,
        opts
      ) do
    %__MODULE__{
      transaction_id: transaction_id,
      request_signature: request_signature,
      hub_id: hub_id,
      originating_node: originating_node,
      reply_to: reply_to,
      node: target_node,
      children: children,
      options: opts,
      status: :dispatched
    }
  end

  ##############################################################################
  # Private helpers
  ##############################################################################

  defp collect_sub_request_results(%__MODULE__{results: nil, children: children}) do
    # For nil results (no response), preserve the full {:error, :no_response} as the error reason
    Enum.map(children, fn child ->
      {:error, Map.get(child, :child_id), {:error, :no_response}}
    end)
  end

  defp collect_sub_request_results(%__MODULE__{results: results, node: node}) do
    Enum.map(results, fn {cid, result} ->
      case result do
        {:ok, pid} -> {:started, cid, node, pid}
        {:error, reason} -> {:error, cid, reason}
        pid when is_pid(pid) -> {:started, cid, node, pid}
      end
    end)
  end

  defp validate_children(request, hub, strategies) do
    local_node = node()
    dist_strat = strategies.dist
    redun_strat = strategies.redun

    # OPTIMIZATION: Check if distribution state changed using signature comparison.
    request_sig = request.request_signature
    current_sig = DistributionStrategy.distribution_signature(dist_strat, hub)
    is_deterministic = DistributionStrategy.deterministic?(dist_strat)

    if request_sig != nil and request_sig == current_sig and is_deterministic do
      # FAST PATH: Topology unchanged and strategy is deterministic.
      Enum.filter(request.children, fn %{nodes: nodes} ->
        Enum.member?(nodes, local_node)
      end)
    else
      # SLOW PATH: Topology changed, no signature, or non-deterministic strategy.
      validate_children_full(
        hub,
        request.children,
        dist_strat,
        redun_strat,
        to_start_opts(request)
      )
    end
  end

  defp validate_children_full(hub, children, dist_strat, redun_strat, start_opts) do
    local_node = node()
    cids = Enum.map(children, & &1.child_spec.id)

    cid_node_pairs =
      DistributionStrategy.belongs_to(
        dist_strat,
        hub,
        Keyword.get(start_opts, :init_cids, cids),
        RedundancyStrategy.replication_factor(redun_strat)
      )
      |> Enum.filter(fn {cid, _} -> Enum.member?(cids, cid) end)

    {valid, forw} =
      Enum.reduce(children, {[], []}, fn %{child_id: cid, nodes: n_orig} = cdata, {valid, forw} ->
        nodes = Bag.get_by_key(cid_node_pairs, cid, [])

        case Enum.member?(nodes, local_node) do
          true ->
            {[cdata | valid], forw}

          false ->
            {valid, populate_forward(forw, nodes, n_orig, cdata)}
        end
      end)

    if length(forw) > 0 do
      insert_pending_entries(hub, forw)
      node_start_requests = create_forward_requests(hub, forw, start_opts)
      Dispatcher.children_start(hub, node_start_requests)
      HookManager.dispatch_hook(hub.storage.hook, Hook.forwarded_migration(), forw)
    end

    valid
  end

  defp insert_pending_entries(hub, forw_data) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    for {target_node, children_list} <- forw_data,
        child_data <- children_list,
        ProcessRegistry.lookup(hub.hub_id, child_data.child_spec.id) == nil do
      child_spec = child_data.child_spec
      metadata = Map.get(child_data, :metadata, %{})

      pending_metadata =
        Map.merge(metadata, %{
          pending: true,
          forwarded_at: timestamp,
          target_nodes: [target_node]
        })

      ProcessRegistry.insert(
        hub.hub_id,
        child_spec,
        [],
        metadata: pending_metadata,
        ttl: @pending_ttl_ms
      )
    end

    :ok
  end

  defp populate_forward(forw_data, valid_nodes, invalid_nodes, child_data) do
    new_nodes = Enum.reject(valid_nodes, &(&1 in invalid_nodes))
    RequestManager.populate_forward(forw_data, new_nodes, child_data)
  end

  defp create_forward_requests(hub, forw, start_opts) do
    transaction_id = make_ref()
    dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())
    request_signature = DistributionStrategy.distribution_signature(dist_strat, hub)
    originating_node = node()
    reply_to = Keyword.get(start_opts, :reply_to)

    passthrough_opts =
      Keyword.drop(start_opts, [:reply_to, :transaction_id, :hub_id, :originating_node])

    Enum.map(forw, fn {target_node, children} ->
      updated_children = Enum.map(children, fn child -> %{child | nodes: [target_node]} end)

      build_request(
        hub.hub_id,
        transaction_id,
        request_signature,
        originating_node,
        reply_to,
        target_node,
        updated_children,
        passthrough_opts
      )
    end)
  end

  defp start_children(hub, validated_children, start_opts) do
    disable_logging = Keyword.get(start_opts, :disable_logging, false)
    ds = hub.procs.dist_sup
    local_node = node()

    Enum.map(validated_children, fn child_data ->
      child_data =
        HookManager.dispatch_alter_hook(hub.storage.hook, Hook.child_data_alter(), child_data)

      startup_result = DistributedSupervisor.start_child(ds, child_data.child_spec)

      case startup_result do
        {:ok, pid} ->
          format_start_resp(child_data, local_node, pid, startup_result)

        {:error, {:already_started, pid}} ->
          format_start_resp(child_data, local_node, pid, startup_result)

        err ->
          if disable_logging === false do
            LoggerService.error(
              "Child start failed with @error. Enable SASL logs for more information.",
              %{"error" => err},
              prefix: "StartChildrenRequest"
            )
          end

          format_start_resp(child_data, local_node, nil, startup_result)
      end
    end)
  end

  defp format_start_resp(child_data, local_node, pid, startup_result) do
    %PostStartData{
      cid: child_data.child_spec.id,
      pid: pid,
      child_spec: child_data.child_spec,
      result: startup_result,
      nodes: child_data.nodes,
      child_nodes: [{local_node, pid}],
      metadata: child_data.metadata,
      has_errors: !is_pid(pid),
      for_node: local_node
    }
  end

  defp dispatch_post_start_hook(hub, post_start_results) do
    post_data =
      Enum.map(post_start_results, fn %PostStartData{cid: cid, result: rs, pid: pid, nodes: n} ->
        {cid, rs, pid, n}
      end)

    HookManager.dispatch_hook(hub.storage.hook, Hook.post_children_start(), post_data)
  end

  defp update_registry(hub, post_start_results) do
    # Insert into local registry
    ProcessRegistry.bulk_insert(
      hub.hub_id,
      store_format(post_start_results),
      hook_storage: hub.storage.hook
    )
  end

  defp send_response(post_start_results, start_opts) do
    results = build_node_response(post_start_results)

    RequestManager.send_response(
      :operation_response,
      start_opts,
      results
    )
  end

  defp sync_propagate(hub, post_start_results, sync_strategy) do
    if !Enum.empty?(post_start_results) do
      request =
        ProcessHub.Request.Handler.PidsRegisterRequest.new(store_format(post_start_results))

      SynchronizationStrategy.propagate(
        sync_strategy,
        hub,
        RequestManager.split(request),
        members: :external
      )
    end
  end

  defp execute_post_action(%PostAction{m: m, f: f, a: a}, hub, results) do
    apply(m, f, [hub, results | a])
  end
end
