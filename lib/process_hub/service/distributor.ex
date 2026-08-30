defmodule ProcessHub.Service.Distributor do
  @moduledoc """
  The distributor service provides API functions for distributing child processes.
  """

  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.RequestManager
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.RequestManager
  alias ProcessHub.Request.Handler.PidsUnregisterRequest
  alias ProcessHub.Request.Handler.StartChildrenRequest
  alias ProcessHub.Request.Handler.StopChildrenRequest
  alias ProcessHub.Service.Cluster
  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Hub

  # 10 seconds
  @default_init_timeout 10000

  # Default timeout values for GenServer.call in bulk operations
  @base_call_timeout 5000
  @timeout_per_child 1

  @doc """
  Calculates the GenServer.call timeout based on child count.

  The timeout is calculated as `@base_call_timeout + (child_count * @timeout_per_child)`,
  which equals `5000ms + (1ms × child_count)`.

  Allows user override via `:call_timeout` option.

  ## Examples

      iex> ProcessHub.Service.Distributor.calculate_call_timeout(100, [])
      5100

      iex> ProcessHub.Service.Distributor.calculate_call_timeout(10000, [])
      15000

      iex> ProcessHub.Service.Distributor.calculate_call_timeout(30000, [])
      35000

      iex> ProcessHub.Service.Distributor.calculate_call_timeout(100, call_timeout: :infinity)
      :infinity

      iex> ProcessHub.Service.Distributor.calculate_call_timeout(100, call_timeout: 60000)
      60000

  """
  @spec calculate_call_timeout(non_neg_integer(), keyword()) :: timeout()
  def calculate_call_timeout(child_count, opts) do
    case Keyword.get(opts, :call_timeout) do
      nil -> @base_call_timeout + child_count * @timeout_per_child
      timeout -> timeout
    end
  end

  @doc "Composes and dispatches a start children operation."
  @spec compose_start_operation(Hub.t(), [ProcessHub.child_spec()], keyword()) ::
          {:ok, RequestManager.t()}
          | {:error,
             :no_children
             | {:already_started, [ProcessHub.child_id()]}
             | any()}
  def compose_start_operation(_hub, [], _opts), do: {:error, :no_children}

  def compose_start_operation(hub, child_specs, opts) do
    with {:ok, strategies} <- init_strategies(hub),
         :ok <- init_distribution(hub, child_specs, opts, strategies),
         :ok <- init_registry_check(hub, child_specs, opts),
         {:ok, mappings} <- init_attach_nodes(hub, child_specs, strategies),
         {:ok, nodes_data} <- init_compose_data(hub, mappings, opts) do
      build_and_dispatch_start(hub, nodes_data, opts)
    end
  end

  # Builds and dispatches the start operation
  defp build_and_dispatch_start(hub, nodes_data, opts) do
    dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())
    signature = DistributionStrategy.distribution_signature(dist_strat, hub)
    opts = Keyword.put(opts, :request_signature, signature)

    operation = RequestManager.new(hub, StartChildrenRequest, nodes_data, opts)
    dispatch_operation(hub, operation)
  end

  @doc "Composes and dispatches a stop children operation."
  @spec compose_stop_operation(Hub.t(), [ProcessHub.child_id()], keyword()) ::
          {:ok, RequestManager.t()} | {:error, :no_children}
  def compose_stop_operation(_hub, [], _opts), do: {:error, :no_children}

  def compose_stop_operation(hub, child_ids, opts) do
    # Group children by the nodes where they exist
    # Also track children that were not found
    {nodes_data, not_found} =
      Enum.reduce(child_ids, {[], []}, fn child_id, {acc, not_found_acc} ->
        registry_result = ProcessRegistry.lookup(hub.hub_id, child_id)

        case registry_result do
          nil ->
            # Child not found in registry
            {acc, [child_id | not_found_acc]}

          {_, node_pids} ->
            child_nodes = Keyword.keys(node_pids)
            child_data = %{nodes: child_nodes, child_id: child_id}

            append_items =
              Enum.map(child_nodes, fn child_node ->
                existing_children = acc[child_node] || []
                {child_node, [child_data | existing_children]}
              end)

            {Keyword.merge(acc, append_items), not_found_acc}
        end
      end)

    case {nodes_data, not_found} do
      {[], []} ->
        # No children specified
        {:error, :no_children}

      {[], not_found_children} ->
        # All children were not found - still create an operation so awaitable works
        # The operation will have empty nodes_data and complete immediately with errors
        opts_with_not_found = Keyword.put(opts, :not_found_children, not_found_children)
        operation = RequestManager.new(hub, StopChildrenRequest, [], opts_with_not_found)
        {:ok, operation}

      _ ->
        # Some children exist - proceed with normal stop
        # Pass not_found to include them as errors in the result
        opts_with_not_found = Keyword.put(opts, :not_found_children, not_found)
        operation = RequestManager.new(hub, StopChildrenRequest, nodes_data, opts_with_not_found)
        dispatch_operation(hub, operation)
    end
  end

  # Dispatches an operation's sub-requests to target nodes
  defp dispatch_operation(hub, %RequestManager{} = operation) do
    case RequestManager.compose_sub_requests(operation) do
      {:ok, updated_operation} ->
        # Dispatch sub-requests based on handler type
        case updated_operation.handler do
          StartChildrenRequest ->
            Dispatcher.children_start(hub, updated_operation.sub_requests)

          StopChildrenRequest ->
            Dispatcher.children_stop(hub, updated_operation.sub_requests)
        end

        {:ok, updated_operation}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Terminates child processes locally and propagates all nodes in the cluster
  to remove the child processes from their registry.

  ## Options
    - `:on_empty` - see `unregister_bindings/3`.
  """
  @spec children_terminate(Hub.t(), [ProcessHub.child_id()], keyword()) ::
          [{ProcessHub.child_id(), term(), node()}]
  def children_terminate(hub, child_ids, opts \\ []) do
    dist_sup = hub.procs.dist_sup

    stop_results =
      Enum.map(child_ids, fn child_id ->
        result = DistributedSupervisor.terminate_child(dist_sup, child_id)
        {child_id, result, node()}
      end)

    stop_results
    |> Enum.filter(fn {_child_id, result, _node} -> result == :ok end)
    |> Enum.map(fn {child_id, _result, node} -> {child_id, [node]} end)
    |> then(&unregister_bindings(hub, &1, opts))

    stop_results
  end

  @doc """
  Withdraws `[{child_id, [node]}]` bindings from the local registry and every
  peer's.

  ## Options
    - `:on_empty` - applied locally and on every peer; see
      `ProcessHub.Service.ProcessRegistry.bulk_delete/3` for the values. Defaults
      to `:churn`, which is what placement churn (migration, redistribution) wants.
  """
  @spec unregister_bindings(Hub.t(), [{ProcessHub.child_id(), [node()]}], keyword()) :: :ok
  def unregister_bindings(hub, cid_nodes, opts \\ [])

  def unregister_bindings(_hub, [], _opts), do: :ok

  def unregister_bindings(hub, cid_nodes, opts) do
    on_empty = Keyword.get(opts, :on_empty, :churn)

    ProcessRegistry.bulk_delete(hub.hub_id, cid_nodes,
      hook_storage: hub.storage.hook,
      on_empty: on_empty
    )

    Dispatcher.propagate_event(hub, PidsUnregisterRequest.new(cid_nodes, on_empty: on_empty),
      members: :external
    )

    :ok
  end

  @doc """
  Returns all child processes started by the local node.

  Works similar to `Supervisor.which_children/1` but returns a list of tuple
  where the first element is the node name and the second child processes started under the node.
  """
  @spec which_children_local(Hub.t(), keyword() | nil) ::
          {node(),
           [{any, :restarting | :undefined | pid, :supervisor | :worker, :dynamic | list}]}
  def which_children_local(hub, _opts) do
    {node(), Supervisor.which_children(hub.procs.dist_sup)}
  end

  @doc """
  Return a list of all child processes started by all nodes in the cluster.
  """
  @spec which_children_global(Hub.t(), keyword()) :: list
  def which_children_global(hub, opts) do
    timeout = Keyword.get(opts, :timeout, 5000)

    Cluster.nodes(hub.storage.misc, [:include_local])
    |> :erpc.multicall(fn -> __MODULE__.which_children_local(hub, opts) end, timeout)
    |> Enum.map(fn {_status, result} -> result end)
  end

  @doc """
  Applies default initialization options to the provided options keyword list.

  This function takes a keyword list of options and merges it with sensible default
  values for process initialization operations. Only missing keys are added; existing
  values in the input options are preserved.

  ## Parameters
  - `opts` - A keyword list of initialization options

  ## Default Values Applied
  - `:timeout` - `#{@default_init_timeout}` ms (#{@default_init_timeout / 1000} seconds) - Maximum time to wait for process initialization
  - `:awaitable` - `false` - Whether to return an awaitable `ProcessHub.Future.t()` struct
  - `:check_existing` - `true` - Whether to check if processes already exist before starting
  - `:on_failure` - `:continue` - Action on failure (`:continue` or `:rollback`)
  - `:metadata` - `%{}` - Additional metadata to attach to processes
  - `:init_cids` - `[]` - List of child IDs expected to be initialized

  ## Examples
      iex> ProcessHub.Service.Distributor.default_init_opts([timeout: 5000, awaitable: true])
      [
        timeout: 5000,
        awaitable: true,
        check_existing: true,
        on_failure: :continue,
        metadata: %{},
        init_cids: []
      ]

  """
  @spec default_init_opts(keyword()) :: keyword()
  def default_init_opts(opts) do
    opts
    |> default_operation_opts()
    |> Keyword.put_new(:check_existing, true)
    |> Keyword.put_new(:on_failure, :continue)
    |> Keyword.put_new(:metadata, %{})
    |> Keyword.put_new(:init_cids, [])
  end

  @doc """
  Applies the default options shared by every start and stop operation.

  Stop operations use this directly - the start-only defaults applied by
  `default_init_opts/1` are not read on the stop path. A `:timeout` that is
  not a non-negative integer is replaced by the default.
  """
  @spec default_operation_opts(keyword()) :: keyword()
  def default_operation_opts(opts) do
    opts
    |> Keyword.update(:timeout, @default_init_timeout, &valid_timeout/1)
    |> Keyword.put_new(:awaitable, false)
  end

  defp valid_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: timeout
  defp valid_timeout(_), do: @default_init_timeout

  defp init_distribution(hub, child_specs, opts, %{distribution: strategy}) do
    DistributionStrategy.children_init(strategy, hub, child_specs, opts)
  end

  defp init_strategies(%Hub{storage: %{misc: misc_storage}}) do
    {:ok,
     %{
       distribution: Storage.get(misc_storage, StorageKey.strdist()),
       redundancy: Storage.get(misc_storage, StorageKey.strred())
     }}
  end

  defp init_data(child_nodes, hub_id, child_spec, metadata) do
    %{
      hub_id: hub_id,
      nodes: child_nodes,
      child_id: child_spec.id,
      child_spec: child_spec,
      metadata: metadata
    }
  end

  defp init_compose_data(
         %Hub{hub_id: hub_id, storage: %{misc: misc_storage}} = hub,
         children,
         opts
       ) do
    global_metadata = Keyword.get(opts, :metadata, %{})
    child_metadata_map = Keyword.get(opts, :child_metadata, %{})

    # Compute distribution signature once for all children
    dist_strat = Storage.get(misc_storage, StorageKey.strdist())
    topology_sig = DistributionStrategy.distribution_signature(dist_strat, hub)

    {:ok,
     Enum.reduce(children, [], fn {child_spec, child_nodes}, acc ->
       # Use per-child metadata if available, otherwise fall back to global metadata
       metadata = Map.get(child_metadata_map, child_spec.id, global_metadata)

       child_data =
         init_data(child_nodes, hub_id, child_spec, metadata)
         |> Map.put(:topology_signature, topology_sig)

       append_items =
         Enum.map(child_nodes, fn child_node ->
           existing_children = acc[child_node] || []

           {child_node, [child_data | existing_children]}
         end)

       Keyword.merge(acc, append_items)
     end)}
  end

  defp init_attach_nodes(hub, child_specs, %{distribution: dist, redundancy: redun}) do
    repl_fact = RedundancyStrategy.replication_factor(redun)
    cids = Enum.map(child_specs, & &1.id)
    cid_nodes_map = DistributionStrategy.belongs_to(dist, hub, cids, repl_fact)

    {
      :ok,
      Enum.map(child_specs, fn child_spec ->
        {
          child_spec,
          Map.get(cid_nodes_map, child_spec.id, [])
        }
      end)
    }
  end

  defp init_registry_check(%Hub{hub_id: hub_id}, child_specs, opts) do
    case Keyword.get(opts, :check_existing) do
      true ->
        contains = ProcessRegistry.contains_children(hub_id, Enum.map(child_specs, & &1.id))

        case contains do
          [] -> :ok
          _ -> {:error, {:already_started, contains}}
        end

      false ->
        :ok
    end
  end
end
