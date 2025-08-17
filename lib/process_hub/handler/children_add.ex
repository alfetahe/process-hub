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
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
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

  defmodule SyncHandle do
    @moduledoc """
    Handler for synchronizing added child processes.
    """

    @type t :: %__MODULE__{
            hub_id: ProcessHub.hub_id(),
            post_start_results: [%PostStartData{}],
            start_opts: keyword()
          }

    @enforce_keys [
      :hub_id,
      :post_start_results,
      :start_opts
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{hub_id: hub_id, post_start_results: psr, start_opts: start_opts}) do
      ProcessRegistry.bulk_insert(hub_id, store_format(psr))

      send_collect_results(psr, start_opts)
    end

    defp send_collect_results(post_start_results, start_opts) do
      reply_to = Keyword.get(start_opts, :reply_to, nil)
      local_node = node()

      # Each node sends only their own child process startup results.
      receiver_data =
        Enum.filter(post_start_results, fn %PostStartData{for_node: {for_node, _}} ->
          for_node === local_node
        end)
        |> Enum.map(fn %PostStartData{cid: cid, result: res} ->
          {cid, res}
        end)

      if reply_to do
        Enum.each(reply_to, fn respondent ->
          send(respondent, {:collect_start_results, receiver_data, local_node})
        end)
      end
    end

    defp store_format(post_start_results) do
      post_start_results
      |> Enum.filter(fn %PostStartData{has_errors: has_err} -> has_err === false end)
      |> Enum.map(fn %PostStartData{cid: cid, child_spec: cs, child_nodes: cn, metadata: m} ->
        {cid, {cs, cn, m}}
      end)
      |> Map.new()
    end
  end

  defmodule StartHandle do
    @moduledoc """
    Handler for starting child processes.
    """
    @type t :: %__MODULE__{
            children: [
              %{
                child_spec: ProcessHub.child_spec(),
                metadata: ProcessHub.child_metadata()
              }
            ],
            hub: Hub.t(),
            sync_strategy: SynchronizationStrategy.t(),
            redun_strategy: RedundancyStrategy.t(),
            dist_strategy: DistributionStrategy.t(),
            migr_strategy: MigrationStrategy.t(),
            start_opts: keyword(),
            process_data: [%PostStartData{}]
          }

    @enforce_keys [
      :children,
      :start_opts,
      :hub
    ]
    defstruct @enforce_keys ++
                [
                  :sync_strategy,
                  :redun_strategy,
                  :migr_strategy,
                  :dist_strategy,
                  :process_data
                ]

    @spec handle(t()) :: :ok | {:error, :partitioned}
    def handle(%__MODULE__{} = arg) do
      arg = %__MODULE__{
        arg
        | sync_strategy: Storage.get(arg.hub.storage.local, StorageKey.strsyn()),
          redun_strategy: Storage.get(arg.hub.storage.local, StorageKey.strred()),
          dist_strategy: Storage.get(arg.hub.storage.local, StorageKey.strdist()),
          migr_strategy: Storage.get(arg.hub.storage.local, StorageKey.strmigr())
      }

      case ProcessHub.Service.State.is_partitioned?(arg.hub.hub_id) do
        true ->
          {:error, :partitioned}

        false ->
          %__MODULE__{arg | process_data: start_children(arg)}
          |> post_start_hook()
          |> update_registry()
          |> dispatch_process_startups()
          |> handle_sync_callback()
          |> release_lock()

          :ok
      end
    end

    defp handle_sync_callback(
           %__MODULE__{hub: %{hub_id: hub_id}, sync_strategy: ss, process_data: pd} = arg
         ) do
      SynchronizationStrategy.propagate(
        ss,
        hub_id,
        pd,
        node(),
        :add,
        members: :external
      )

      arg
    end

    defp dispatch_process_startups(%__MODULE__{hub: %{hub_id: hub_id}, process_data: pd} = arg) do
      HookManager.dispatch_hook(
        hub_id,
        Hook.process_startups(),
        pd
      )

      arg
    end

    defp update_registry(
           %__MODULE__{hub: %{hub_id: hub_id}, process_data: pd, start_opts: so} = arg
         ) do
      Task.Supervisor.async(
        arg.hub.managers.task_supervisor,
        SyncHandle,
        :handle,
        [
          %SyncHandle{
            hub_id: hub_id,
            post_start_results: pd,
            start_opts: so
          }
        ]
      )
      |> Task.await()

      arg
    end

    defp release_lock(%__MODULE__{hub: %{hub_id: hub_id}, start_opts: so}) do
      # Release the event queue lock only when migrating
      # processes rather than regular startup.
      if Keyword.get(so, :migration_add, false) === true do
        State.unlock_event_handler(hub_id)
      end
    end

    defp start_children(
           %__MODULE__{
             hub: %{hub_id: hub_id, managers: %{distributed_supervisor: ds}},
             start_opts: so
           } = arg
         ) do
      # Used only for testing purposes.
      disable_logging = Keyword.get(so, :disable_logging, false)

      HookManager.dispatch_hook(hub_id, Hook.pre_children_start(), arg)

      local_node = node()

      validate_children(arg)
      |> Enum.map(fn child_data ->
        child_data = HookManager.dispatch_alter_hook(hub_id, Hook.child_data_alter(), child_data)

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

    defp post_start_hook(%__MODULE__{process_data: ps} = arg) do
      post_data =
        Enum.reduce(ps, [], fn %PostStartData{cid: cid, result: rs, pid: pid, nodes: n}, acc ->
          [{cid, rs, pid, n} | acc]
        end)

      HookManager.dispatch_hook(arg.hub.hub_id, Hook.post_children_start(), post_data)

      arg
    end

    defp validate_children(%__MODULE__{
           hub: %{hub_id: hub_id},
           children: children,
           dist_strategy: dist_strat,
           redun_strategy: redun_strat,
           start_opts: start_opts
         }) do
      # Check if the child belongs to this node.
      local_node = node()
      replication_factor = RedundancyStrategy.replication_factor(redun_strat)

      {valid, forw} =
        Enum.reduce(children, {[], []}, fn %{child_id: cid, nodes: n_orig} = cdata,
                                           {valid, forw} ->
          nodes = DistributionStrategy.belongs_to(dist_strat, hub_id, cid, replication_factor)

          # Recheck if the child processes that are supposed to be started current node are
          # still assigned to current node or not. If not then forward to the correct node.
          #
          # These cases can happen when multiple nodes are added to the cluster simultaneously.
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
        Dispatcher.children_start(hub_id, forw, start_opts)
        HookManager.dispatch_hook(hub_id, Hook.forwarded_migration(), forw)
      end

      # Return the filtered list of valid children for this node.
      valid
    end

    defp populate_forward(forw_data, nodes_valid, nodes_invalid, child_data) do
      forw_nodes = Enum.filter(nodes_valid, fn node -> !Enum.member?(nodes_invalid, node) end)

      updated_forw =
        Enum.map(forw_nodes, fn forw_node ->
          {forw_node, [child_data | Keyword.get(forw_data, forw_node, [])]}
        end)

      Keyword.merge(forw_data, updated_forw)
    end
  end
end
