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
  alias ProcessHub.Utility.Name

  use Task

  defmodule PostStartData do
    @type t :: %__MODULE__{
            cid: ProcessHub.child_id(),
            pid: pid(),
            child_spec: ProcessHub.child_spec(),
            result: {:ok, pid()} | {:error, term()} | term(),
            child_nodes: [{node(), pid()}],
            nodes: [node()],
            for_node: {
              node(),
              [
                {:reply_to, ProcessHub.reply_to()},
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
      :nodes
    ]
  end

  defmodule SyncHandle do
    @moduledoc """
    Handler for synchronizing added child processes.
    """

    @type t :: %__MODULE__{
            hub_id: ProcessHub.hub_id(),
            post_start_results: [%PostStartData{}]
          }

    @enforce_keys [
      :hub_id,
      :post_start_results
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{hub_id: hub_id, post_start_results: psr}) do
      children_formatted =
        Enum.map(psr, fn %PostStartData{cid: cid, child_spec: cs, child_nodes: cn} ->
          {cid, {cs, cn}}
        end)
        |> Map.new()

      ProcessRegistry.bulk_insert(hub_id, children_formatted)

      local_node = node()

      # Not all nodes should handle the reply_to options or we will end up with multiple replies.
      Enum.each(psr, fn %PostStartData{cid: cid, result: rs, for_node: {for_node, opts}} ->
        if for_node === local_node do
          handle_reply_to(opts, cid, rs, for_node)
        end
      end)
    end

    defp handle_reply_to(opts, child_id, startup_res, local_node) do
      reply_to = Keyword.get(opts, :reply_to, nil)

      if is_list(reply_to) and length(reply_to) > 0 do
        Dispatcher.reply_respondents(
          reply_to,
          :child_start_resp,
          child_id,
          startup_res,
          local_node
        )
      end
    end
  end

  defmodule StartHandle do
    @moduledoc """
    Handler for starting child processes.
    """

    @type t :: %__MODULE__{
            hub_id: ProcessHub.hub_id(),
            children: [
              %{
                child_spec: ProcessHub.child_spec(),
                reply_to: ProcessHub.reply_to()
              }
            ],
            dist_sup: atom(),
            sync_strategy: SynchronizationStrategy.t(),
            redun_strategy: RedundancyStrategy.t(),
            dist_strategy: DistributionStrategy.t(),
            migr_strategy: MigrationStrategy.t(),
            start_opts: keyword(),
            process_data: [%PostStartData{}]
          }

    @enforce_keys [
      :hub_id,
      :children,
      :start_opts
    ]
    defstruct @enforce_keys ++
                [
                  :dist_sup,
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
        | dist_sup: Name.distributed_supervisor(arg.hub_id),
          sync_strategy: Storage.get(arg.hub_id, StorageKey.strsyn()),
          redun_strategy: Storage.get(arg.hub_id, StorageKey.strred()),
          dist_strategy: Storage.get(arg.hub_id, StorageKey.strdist()),
          migr_strategy: Storage.get(arg.hub_id, StorageKey.strmigr())
      }

      case ProcessHub.Service.State.is_partitioned?(arg.hub_id) do
        true ->
          {:error, :partitioned}

        false ->
          %__MODULE__{arg | process_data: start_children(arg)}
          |> post_start_hook()
          |> update_registry()
          |> handle_migration_callback()
          |> handle_sync_callback()
          |> release_lock()

          :ok
      end
    end

    defp handle_sync_callback(
           %__MODULE__{hub_id: hub_id, sync_strategy: ss, process_data: pd} = arg
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

    defp handle_migration_callback(
           %__MODULE__{hub_id: hub_id, migr_strategy: ms, process_data: pd} = arg
         ) do
      MigrationStrategy.handle_process_startups(
        ms,
        hub_id,
        Enum.map(pd, fn %{cid: cid, pid: pid} ->
          {cid, pid}
        end)
      )

      arg
    end

    defp update_registry(%__MODULE__{hub_id: hub_id, process_data: pd} = arg) do
      Task.Supervisor.async(
        Name.task_supervisor(hub_id),
        SyncHandle,
        :handle,
        [
          %SyncHandle{
            hub_id: hub_id,
            post_start_results: pd
          }
        ]
      )
      |> Task.await()

      arg
    end

    defp release_lock(%__MODULE__{hub_id: hub_id, start_opts: so}) do
      # Release the event queue lock only when migrating
      # processes rather than regular startup.
      if Keyword.get(so, :migration_add, false) === true do
        State.unlock_event_handler(hub_id)
      end
    end

    defp start_children(%__MODULE__{hub_id: hub_id, dist_sup: ds} = arg) do
      HookManager.dispatch_hook(hub_id, Hook.pre_children_start(), arg)

      local_node = node()

      validate_children(arg)
      |> Enum.map(fn child_data ->
        startup_result = child_start_result(child_data, ds, local_node)

        case startup_result do
          {:ok, pid} ->
            format_start_resp(child_data, local_node, pid, startup_result)

          {:error, {:already_started, pid}} ->
            format_start_resp(child_data, local_node, pid, startup_result)

          _ ->
            Logger.error(
              "Unexpected message received while starting child: #{inspect(child_data)}"
            )

            nil
        end
      end)
      |> Enum.filter(&(&1 !== nil))
    end

    defp format_start_resp(child_data, local_node, pid, startup_result) do
      %PostStartData{
        cid: child_data.child_spec.id,
        pid: pid,
        child_spec: child_data.child_spec,
        result: startup_result,
        nodes: child_data.nodes,
        child_nodes: [{local_node, pid}],
        for_node: {
          local_node,
          [
            {:reply_to, Map.get(child_data, :reply_to, [])},
            {:migration, Map.get(child_data, :migration, false)}
          ]
        }
      }
    end

    defp post_start_hook(
           %__MODULE__{redun_strategy: rs, dist_strategy: ds, process_data: ps} = arg
         ) do
      post_data =
        Enum.reduce(ps, [], fn %PostStartData{cid: cid, pid: pid, result: rs, nodes: n}, acc ->
          case rs do
            {:ok, _} ->
              [{cid, pid, n} | acc]

            _ ->
              acc
          end
        end)

      RedundancyStrategy.handle_post_start(rs, ds, post_data)

      arg
    end

    defp child_start_result(child_data, dist_sup, local_node) do
      cid = child_data.child_spec.id

      case DistributedSupervisor.start_child(dist_sup, child_data.child_spec) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          {:error, {:already_started, pid}}

        any ->
          Map.get(child_data, :reply_to, [])
          |> Dispatcher.reply_respondents(:child_start_resp, cid, any, local_node)
      end
    end

    defp validate_children(%__MODULE__{
           hub_id: hub_id,
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
