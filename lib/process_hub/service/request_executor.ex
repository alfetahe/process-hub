defmodule ProcessHub.Service.RequestExecutor do
  @moduledoc """
  Service for executing cross-node requests with reusable utilities.

  Provides common patterns used by ChildStartRequest and NodeStopRequest
  when executing cross-node operations.
  """

  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.State
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Request.Handler.StartChildrenRequest.ChildStartRequest
  alias ProcessHub.Hub

  @doc """
  Wraps function execution with partition check.
  Returns `{:error, :partitioned}` if the hub is partitioned,
  otherwise executes the function and returns its result.
  """
  @spec with_partition_check(Hub.t(), (-> term())) :: term() | {:error, :partitioned}
  def with_partition_check(hub, fun) do
    case State.is_partitioned?(hub) do
      true -> {:error, :partitioned}
      false -> fun.()
    end
  end

  @doc """
  Loads all strategies from storage and returns them as a map.
  """
  @spec load_strategies(Hub.t()) :: %{
          sync: term(),
          dist: term(),
          redun: term(),
          migr: term()
        }
  def load_strategies(hub) do
    %{
      sync: Storage.get(hub.storage.misc, StorageKey.strsyn()),
      dist: Storage.get(hub.storage.misc, StorageKey.strdist()),
      redun: Storage.get(hub.storage.misc, StorageKey.strred()),
      migr: Storage.get(hub.storage.misc, StorageKey.strmigr())
    }
  end

  @doc """
  Sends unified response to coordinator.

  ## Parameters
    - `response_type` - `:start_children_response` or `:stop_children_response`
    - `opts` - Keyword list with routing info (`:hub_id`, `:transaction_id`, `:originating_node`)
    - `results` - List of `{child_id, result}` tuples

  ## Returns
    - `:ok` if response was sent
    - `:skip` if no transaction info present (legacy mode)
  """
  @spec send_response(atom(), keyword(), [{ProcessHub.child_id(), term()}]) :: :ok | :skip
  def send_response(response_type, opts, results) do
    hub_id = Keyword.get(opts, :hub_id)
    transaction_id = Keyword.get(opts, :transaction_id)

    if hub_id && transaction_id do
      originating_node = Keyword.get(opts, :originating_node, node())
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
  Converts any child request struct to keyword options for response routing.

  Works with any struct that has the standard routing fields:
  - `transaction_id`
  - `hub_id`
  - `originating_node`
  - `reply_to`
  - `options`

  ## Parameters
    - `request` - A ChildStartRequest or ChildStopRequest struct

  ## Returns
    Keyword list with routing information.
  """
  @spec child_request_to_opts(map()) :: keyword()
  def child_request_to_opts(request) do
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

    opts = if request.reply_to, do: [{:reply_to, request.reply_to} | opts], else: opts
    opts
  end

  @doc """
  Factory: Creates a migration request for ColdSwap topology expansion.

  ## Parameters
    - `hub` - The Hub struct
    - `target_node` - Node to send children to
    - `children_data` - List of `{child_spec, metadata}` tuples
    - `opts` - Additional options (default: [])

  ## Returns
    A ChildStartRequest configured for migration.
  """
  @spec migration_request(Hub.t(), node(), [{ProcessHub.child_spec(), map()}], keyword()) ::
          ChildStartRequest.t()
  def migration_request(hub, target_node, children_data, opts \\ []) do
    dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())
    request_signature = DistributionStrategy.distribution_signature(dist_strat, hub)

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

    %ChildStartRequest{
      transaction_id: make_ref(),
      request_signature: request_signature,
      hub_id: hub.hub_id,
      originating_node: node(),
      reply_to: nil,
      node: target_node,
      children: children,
      options: opts,
      status: :dispatched
    }
  end

  @doc """
  Factory: Creates a contraction request for ColdSwap topology contraction.

  ## Parameters
    - `hub` - The Hub struct
    - `children_data` - List of `{child_spec, metadata}` tuples
    - `opts` - Additional options (default: [migration_add: true])

  ## Returns
    A ChildStartRequest configured for contraction (local start).
  """
  @spec contraction_request(Hub.t(), [{ProcessHub.child_spec(), map()}], keyword()) ::
          ChildStartRequest.t()
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

    %ChildStartRequest{
      transaction_id: make_ref(),
      request_signature: request_signature,
      hub_id: hub.hub_id,
      originating_node: local_node,
      reply_to: nil,
      node: local_node,
      children: children,
      options: opts,
      status: :dispatched
    }
  end
end
