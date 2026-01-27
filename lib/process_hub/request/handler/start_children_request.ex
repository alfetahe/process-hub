defmodule ProcessHub.Request.Handler.StartChildrenRequest do
  @moduledoc """
  Represents a request to start child processes across multiple nodes.

  This module encapsulates all the state and logic needed for tracking
  a distributed start children operation, including:
  - Composing and dispatching sub-requests to individual nodes
  - Recording node responses as they arrive
  - Building the final StartResult from aggregated responses
  """

  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.RequestTracker
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Constant.StorageKey

  @default_request_timeout :timer.minutes(10)

  @type t() :: %__MODULE__{
          transaction_id: reference(),
          request_signature: non_neg_integer() | nil,
          hub_id: ProcessHub.hub_id(),
          nodes_data: [{node(), [map()]}],
          child_specs: [ProcessHub.child_spec()],
          sub_requests: [ChildStartRequest.t()],
          future: ProcessHub.Future.t() | nil,
          options: keyword(),
          expires_at: integer(),
          awaiter: {pid(), reference()} | nil,
          completed_nodes: MapSet.t()
        }

  defstruct [
    :transaction_id,
    :request_signature,
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
            for_node: {
              node(),
              [
                {:migration, boolean()}
              ]
            }
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

  defmodule ChildStartRequest do
    @moduledoc """
    Represents a request to start children on a specific target node.

    Contains all data needed for the remote node to start children
    and route responses back to the coordinator.

    Implements `ProcessHub.Request.CrossNodeRequest` protocol for execution
    on the target node.
    """

    require Logger

    alias ProcessHub.DistributedSupervisor
    alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
    alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
    alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
    alias ProcessHub.Service.ProcessRegistry
    alias ProcessHub.Service.RequestSplitter
    alias ProcessHub.Service.Dispatcher
    alias ProcessHub.Service.HookManager
    alias ProcessHub.Service.Storage
    alias ProcessHub.Service.RequestExecutor
    alias ProcessHub.Utility.Bag
    alias ProcessHub.Constant.Hook
    alias ProcessHub.Constant.StorageKey
    alias ProcessHub.Request.Handler.StartChildrenRequest
    alias ProcessHub.Request.Handler.StartChildrenRequest.PostStartData
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
            start_results: [{ProcessHub.child_id(), term()}] | nil,
            caller: pid() | nil,
            status: :pending | :dispatched | :completed
          }

    defstruct [
      :transaction_id,
      :request_signature,
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
    Converts ChildStartRequest to keyword options for backward compatibility
    with existing code that expects start_opts.
    """
    @spec to_start_opts(t()) :: keyword()
    def to_start_opts(%__MODULE__{} = req), do: RequestExecutor.child_request_to_opts(req)

    @doc """
    Executes the start request on the target node.

    This consolidates the logic previously in ChildrenAdd.StartHandle.handle/1.
    """
    @spec execute(t(), Hub.t()) :: :ok | {:error, :partitioned}
    def execute(%__MODULE__{} = request, hub) do
      RequestExecutor.with_partition_check(hub, fn ->
        strategies = RequestExecutor.load_strategies(hub)
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
        update_registry_and_respond(hub, post_start_results, request, start_opts)

        # Sync propagate to other nodes
        sync_propagate(hub, post_start_results, strategies.sync)

        :ok
      end)
    end

    @doc """
    Factory: Creates a migration request for ColdSwap topology expansion.
    """
    @spec for_migration(Hub.t(), node(), [{ProcessHub.child_spec(), map()}]) :: t()
    def for_migration(hub, target_node, children_data) do
      RequestExecutor.migration_request(hub, target_node, children_data)
    end

    @doc """
    Factory: Creates a contraction request for ColdSwap topology contraction.
    """
    @spec for_contraction(Hub.t(), [{ProcessHub.child_spec(), map()}]) :: t()
    def for_contraction(hub, children_data) do
      RequestExecutor.contraction_request(hub, children_data)
    end

    ##############################################################################
    # Private helpers
    ##############################################################################

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
        Enum.reduce(children, {[], []}, fn %{child_id: cid, nodes: n_orig} = cdata,
                                           {valid, forw} ->
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
        Dispatcher.children_start(hub.hub_id, node_start_requests)
        HookManager.dispatch_hook(hub.storage.hook, Hook.forwarded_migration(), forw)
      end

      valid
    end

    defp insert_pending_entries(hub, forw_data) do
      timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

      Enum.each(forw_data, fn {target_node, children_list} ->
        Enum.each(children_list, fn child_data ->
          child_spec = child_data.child_spec
          metadata = Map.get(child_data, :metadata, %{})

          case ProcessRegistry.lookup(hub.hub_id, child_spec.id) do
            nil ->
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

            _existing ->
              :ok
          end
        end)
      end)
    end

    defp populate_forward(forw_data, nodes_valid, nodes_invalid, child_data) do
      forw_nodes = Enum.filter(nodes_valid, fn node -> !Enum.member?(nodes_invalid, node) end)

      updated_forw =
        Enum.map(forw_nodes, fn forw_node ->
          {forw_node, [child_data | Keyword.get(forw_data, forw_node, [])]}
        end)

      Keyword.merge(forw_data, updated_forw)
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
        updated_children =
          Enum.map(children, fn child ->
            %{child | nodes: [target_node]}
          end)

        %__MODULE__{
          transaction_id: transaction_id,
          request_signature: request_signature,
          hub_id: hub.hub_id,
          originating_node: originating_node,
          reply_to: reply_to,
          node: target_node,
          children: updated_children,
          options: passthrough_opts,
          status: :dispatched
        }
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
              Logger.error(
                "Child start failed with #{inspect(err)}. Enable SASL logs for more information."
              )
            end

            format_start_resp(child_data, local_node, nil, startup_result)
        end
      end)
    end

    defp format_start_resp(child_data, local_node, pid, startup_result) do
      has_errors = !is_pid(pid)

      %PostStartData{
        cid: child_data.child_spec.id,
        pid: pid,
        child_spec: child_data.child_spec,
        result: startup_result,
        nodes: child_data.nodes,
        child_nodes: [{local_node, pid}],
        metadata: child_data.metadata,
        has_errors: has_errors,
        for_node: {
          local_node,
          [
            {:migration, Map.get(child_data, :migration, false)}
          ]
        }
      }
    end

    defp dispatch_post_start_hook(hub, post_start_results) do
      post_data =
        Enum.reduce(post_start_results, [], fn %PostStartData{
                                                 cid: cid,
                                                 result: rs,
                                                 pid: pid,
                                                 nodes: n
                                               },
                                               acc ->
          [{cid, rs, pid, n} | acc]
        end)

      HookManager.dispatch_hook(hub.storage.hook, Hook.post_children_start(), post_data)
    end

    defp update_registry_and_respond(hub, post_start_results, _request, start_opts) do
      # Insert into local registry
      ProcessRegistry.bulk_insert(
        hub.hub_id,
        StartChildrenRequest.store_format(post_start_results),
        hook_storage: hub.storage.hook
      )

      # Build and send response
      results = StartChildrenRequest.build_node_response(post_start_results)

      RequestExecutor.send_response(
        :start_children_response,
        start_opts,
        results
      )
    end

    defp sync_propagate(hub, post_start_results, sync_strategy) do
      if !Enum.empty?(post_start_results) do
        request =
          ProcessHub.Request.Handler.PidsRegisterRequest.new(
            StartChildrenRequest.store_format(post_start_results)
          )

        SynchronizationStrategy.propagate(
          sync_strategy,
          hub,
          RequestSplitter.split(request),
          members: :external
        )
      end
    end
  end

  ##############################################################################
  # Helper functions
  ##############################################################################

  @doc """
  Converts post-start results to storage format for registry insertion.
  """
  @spec store_format([PostStartData.t()]) :: map()
  def store_format(post_start_results) do
    post_start_results
    |> Enum.filter(fn %PostStartData{has_errors: has_err} -> has_err === false end)
    |> Enum.map(fn %PostStartData{cid: cid, child_spec: cs, child_nodes: cn, metadata: m} ->
      {cid, {cs, cn, m}}
    end)
    |> Map.new()
  end

  ##############################################################################
  # Request tracking functions
  ##############################################################################

  def new(hub, child_specs, mappings, opts) do
    transaction_id = make_ref()
    timeout = Keyword.get(opts, :request_timeout, @default_request_timeout)
    expires_at = System.monotonic_time(:millisecond) + timeout
    dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())

    future = %ProcessHub.Future{
      future_resolver: {hub.hub_id, node()},
      timeout: Keyword.get(opts, :timeout, 5000),
      ref: transaction_id
    }

    %__MODULE__{
      transaction_id: transaction_id,
      request_signature: DistributionStrategy.distribution_signature(dist_strat, hub),
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

    passthrough_opts =
      Keyword.drop(opts, [:reply_to, :transaction_id, :hub_id, :originating_node])

    sub_requests =
      Enum.map(mappings, fn {target_node, children} ->
        %ChildStartRequest{
          transaction_id: tid,
          request_signature: request.request_signature,
          hub_id: hub_id,
          originating_node: originating,
          reply_to: reply_to,
          node: target_node,
          children: children,
          options: passthrough_opts,
          status: :dispatched
        }
      end)

    Dispatcher.children_start(hub_id, sub_requests)

    {:ok, %{request | sub_requests: sub_requests}}
  end

  @doc """
  Records a node's response to the start children request.
  """
  @spec record_node_response(t(), node(), [{ProcessHub.child_id(), term()}]) :: t()
  def record_node_response(%__MODULE__{} = request, response_node, results) do
    RequestTracker.record_response(request, response_node, results, :start_results)
  end

  @doc """
  Sets the awaiter for this request.
  """
  @spec set_awaiter(t(), {pid(), reference()}) :: t()
  def set_awaiter(%__MODULE__{} = request, from), do: RequestTracker.set_awaiter(request, from)

  @doc """
  Converts a completed request into a StartResult struct.
  """
  @spec to_start_result(t()) :: ProcessHub.StartResult.t()
  def to_start_result(%__MODULE__{} = request) do
    {started, errors} =
      Enum.reduce(request.sub_requests, {[], []}, fn sub_req, {started_acc, errors_acc} ->
        case sub_req.start_results do
          nil ->
            child_errors =
              Enum.map(sub_req.children, fn child ->
                {Map.get(child, :child_id), {:error, :no_response}}
              end)

            {started_acc, errors_acc ++ child_errors}

          results ->
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
  """
  @spec build_node_response([PostStartData.t()]) :: [{ProcessHub.child_id(), term()}]
  def build_node_response(post_start_results) do
    local_node = node()

    post_start_results
    |> Enum.filter(fn %PostStartData{for_node: {for_node, _}} -> for_node === local_node end)
    |> Enum.map(fn %PostStartData{cid: cid, result: res} -> {cid, res} end)
  end
end

##############################################################################
# CrossNodeRequest protocol implementation
##############################################################################

defimpl ProcessHub.Request.CrossNodeRequest,
  for: ProcessHub.Request.Handler.StartChildrenRequest.ChildStartRequest do
  alias ProcessHub.Request.Handler.StartChildrenRequest.ChildStartRequest

  def handle(request, hub) do
    ChildStartRequest.execute(request, hub)
  end
end
