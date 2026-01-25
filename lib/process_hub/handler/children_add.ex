defmodule ProcessHub.Handler.ChildrenAdd do
  @moduledoc false

  require Logger

  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.State
  alias ProcessHub.Service.Storage
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.StartChildrenRequest
  alias ProcessHub.StartChildrenRequest.NodeStartRequest
  alias ProcessHub.Hub

  use Task

  defmodule PostStartData do
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

  # TODO: refactor.
  def store_format(post_start_results) do
    post_start_results
    |> Enum.filter(fn %PostStartData{has_errors: has_err} -> has_err === false end)
    |> Enum.map(fn %PostStartData{cid: cid, child_spec: cs, child_nodes: cn, metadata: m} ->
      {cid, {cs, cn, m}}
    end)
    |> Map.new()
  end

  defmodule SyncHandle do
    @moduledoc """
    Handler for synchronizing added child processes.
    """

    @type t :: %__MODULE__{
            hub: Hub.t(),
            post_start_results: [%PostStartData{}],
            node_start_request: NodeStartRequest.t(),
            start_opts: keyword() | nil
          }

    @enforce_keys [
      :hub,
      :post_start_results
    ]
    defstruct @enforce_keys ++ [:node_start_request, :start_opts]

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{hub: hub, post_start_results: psr} = arg) do
      ProcessRegistry.bulk_insert(hub.hub_id, ProcessHub.Handler.ChildrenAdd.store_format(psr),
        hook_storage: hub.storage.hook
      )

      # Use StartChildrenRequest for response handling
      results = StartChildrenRequest.build_node_response(psr)

      # Route response based on available data
      case arg do
        %{node_start_request: %NodeStartRequest{} = req} ->
          send_response_via_request(req, results)

        %{start_opts: opts} when is_list(opts) ->
          StartChildrenRequest.send_response_to_coordinator(opts, results)

        _ ->
          :ok
      end
    end

    defp send_response_via_request(
           %NodeStartRequest{
             hub_id: hub_id,
             transaction_id: tid,
             originating_node: origin
           },
           results
         )
         when not is_nil(hub_id) and not is_nil(tid) do
      GenServer.cast(
        {hub_id, origin || node()},
        {:start_children_response, tid, node(), results}
      )

      :ok
    end

    defp send_response_via_request(_, _), do: :skip
  end

  defmodule StartHandle do
    @moduledoc """
    Handler for starting child processes.
    """

    # TTL for pending registry entries (10 minutes)
    @pending_ttl_ms :timer.minutes(10)

    @type t :: %__MODULE__{
            hub: Hub.t(),
            node_start_request: NodeStartRequest.t(),
            sync_strategy: SynchronizationStrategy.t(),
            redun_strategy: RedundancyStrategy.t(),
            dist_strategy: DistributionStrategy.t(),
            migr_strategy: MigrationStrategy.t(),
            start_opts: keyword() | nil,
            process_data: [%PostStartData{}]
          }

    @enforce_keys [
      :node_start_request,
      :hub
    ]
    defstruct @enforce_keys ++
                [
                  :start_opts,
                  :sync_strategy,
                  :redun_strategy,
                  :migr_strategy,
                  :dist_strategy,
                  :process_data
                ]

    @doc """
    Returns the effective start options, preferring NodeStartRequest fields
    when available, falling back to start_opts for legacy support.
    """
    @spec effective_start_opts(t()) :: keyword()
    def effective_start_opts(%__MODULE__{node_start_request: %NodeStartRequest{} = req}) do
      NodeStartRequest.to_start_opts(req)
    end

    def effective_start_opts(%__MODULE__{start_opts: opts}) when is_list(opts), do: opts
    def effective_start_opts(%__MODULE__{}), do: []

    @spec handle(t()) :: :ok | {:error, :partitioned}
    def handle(%__MODULE__{} = arg) do
      # Get effective options and set them for internal use
      eff_opts = effective_start_opts(arg)

      arg = %__MODULE__{
        arg
        | start_opts: eff_opts,
          sync_strategy: Storage.get(arg.hub.storage.misc, StorageKey.strsyn()),
          redun_strategy: Storage.get(arg.hub.storage.misc, StorageKey.strred()),
          dist_strategy: Storage.get(arg.hub.storage.misc, StorageKey.strdist()),
          migr_strategy: Storage.get(arg.hub.storage.misc, StorageKey.strmigr())
      }

      case ProcessHub.Service.State.is_partitioned?(arg.hub) do
        true ->
          {:error, :partitioned}

        false ->
          %__MODULE__{arg | process_data: start_children(arg)}
          |> post_start_hook()
          |> update_registry()
          |> dispatch_process_startups()
          |> sync_propagate()

          :ok
      end
    end

    defp sync_propagate(%__MODULE__{} = arg) do
      if !Enum.empty?(arg.process_data) do
        request =
          ProcessHub.Request.Handler.PidsRegisterRequest.new(
            ProcessHub.Handler.ChildrenAdd.store_format(arg.process_data)
          )

        SynchronizationStrategy.propagate(
          arg.sync_strategy,
          arg.hub,
          request,
          members: :external
        )
      end

      arg
    end

    defp dispatch_process_startups(%__MODULE__{hub: hub, process_data: pd} = arg) do
      HookManager.dispatch_hook(
        hub.storage.hook,
        Hook.process_startups(),
        pd
      )

      arg
    end

    defp update_registry(
           %__MODULE__{hub: hub, process_data: pd, node_start_request: nsr, start_opts: so} = arg
         ) do
      Task.Supervisor.async(
        hub.procs.task_sup,
        SyncHandle,
        :handle,
        [
          %SyncHandle{
            hub: hub,
            post_start_results: pd,
            node_start_request: nsr,
            start_opts: so
          }
        ]
      )
      |> Task.await()

      arg
    end

    defp start_children(
           %__MODULE__{
             hub: hub,
             start_opts: so
           } = arg
         ) do
      # Used only for testing purposes.
      disable_logging = Keyword.get(so, :disable_logging, false)
      ds = hub.procs.dist_sup

      HookManager.dispatch_hook(hub.storage.hook, Hook.pre_children_start(), arg)

      local_node = node()
      validated_children = validate_children(arg)

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

    defp post_start_hook(%__MODULE__{process_data: ps, hub: hub} = arg) do
      post_data =
        Enum.reduce(ps, [], fn %PostStartData{cid: cid, result: rs, pid: pid, nodes: n}, acc ->
          [{cid, rs, pid, n} | acc]
        end)

      HookManager.dispatch_hook(hub.storage.hook, Hook.post_children_start(), post_data)

      arg
    end

    defp validate_children(%__MODULE__{
           hub: hub,
           node_start_request: nsr,
           dist_strategy: dist_strat,
           redun_strategy: redun_strat,
           start_opts: start_opts
         }) do
      local_node = node()

      # OPTIMIZATION: Check if distribution state changed using signature comparison.
      # If state is unchanged AND strategy is deterministic, skip expensive
      # belongs_to() revalidation. Non-deterministic strategies (like load-based)
      # may produce different distributions even with same topology.
      request_sig = nsr.request_signature
      current_sig = DistributionStrategy.distribution_signature(dist_strat, hub)
      is_deterministic = DistributionStrategy.deterministic?(dist_strat)

      if request_sig != nil and request_sig == current_sig and is_deterministic do
        # FAST PATH: Topology unchanged and strategy is deterministic.
        # Use pre-computed node assignments from init_attach_nodes.
        Enum.filter(nsr.children, fn %{nodes: nodes} ->
          Enum.member?(nodes, local_node)
        end)
      else
        # SLOW PATH: Topology changed, no signature, or non-deterministic strategy.
        validate_children_full(hub, nsr.children, dist_strat, redun_strat, start_opts)
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
          # Recheck if the child processes that are supposed to be started current node are
          # still assigned to current node or not. If not then forward to the correct node.
          #
          # These cases can happen when multiple nodes are added to the cluster simultaneously.
          nodes = Bag.get_by_key(cid_node_pairs, cid, [])

          case Enum.member?(nodes, local_node) do
            true ->
              {[cdata | valid], forw}

            false ->
              # Find out which nodes are not mentioned in the original list of nodes.
              # These are the nodes that need to be forwarded to.
              {valid, populate_forward(forw, nodes, n_orig, cdata)}
          end
        end)

      if length(forw) > 0 do
        # Insert pending entries before forwarding to ensure children are tracked
        insert_pending_entries(hub, forw)

        node_start_requests = create_forward_requests(hub, forw, start_opts)
        Dispatcher.children_start(hub.hub_id, node_start_requests)

        HookManager.dispatch_hook(hub.storage.hook, Hook.forwarded_migration(), forw)
      end

      # Return the filtered list of valid children for this node.
      valid
    end

    # Inserts pending entries into registry before forwarding to other nodes.
    # These entries have empty nodes list and TTL, ensuring children are tracked
    # even if forwarding fails or times out.
    defp insert_pending_entries(hub, forw_data) do
      timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

      Enum.each(forw_data, fn {target_node, children_list} ->
        Enum.each(children_list, fn child_data ->
          child_spec = child_data.child_spec
          metadata = Map.get(child_data, :metadata, %{})

          # Only insert if not already in registry
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
              # Already exists, skip pending insertion
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

      # Filter out routing options that are set explicitly on the request
      passthrough_opts =
        Keyword.drop(start_opts, [:reply_to, :transaction_id, :hub_id, :originating_node])

      Enum.map(forw, fn {target_node, children} ->
        # Update children.nodes to include the forward target node.
        # This ensures the FAST PATH validation on the receiving node will
        # correctly identify this node as the target.
        updated_children =
          Enum.map(children, fn child ->
            %{child | nodes: [target_node]}
          end)

        %NodeStartRequest{
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
  end
end
