defmodule ProcessHub.Handler.ChildrenAdd do
  @moduledoc false

  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.State
  alias ProcessHub.Service.LocalStorage
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Utility.Name

  use Task

  defmodule SyncHandle do
    @moduledoc """
    Handler for synchronizing added child processes.
    """

    @type process_startup_result() :: {:ok, pid()} | {:error, any()} | term()

    @type t :: %__MODULE__{
            hub_id: ProcessHub.hub_id(),
            children: [
              {
                ProcessHub.child_id(),
                ProcessHub.child_spec(),
                {
                  ProcessHub.reply_to(),
                  process_startup_result()
                }
              }
            ]
          }

    @enforce_keys [
      :hub_id,
      :children
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = arg) do
      children_formatted =
        Enum.map(arg.children, fn {child_id, {_child_spec, _child_nodes} = cn, _, _} ->
          {child_id, cn}
        end)
        |> Map.new()

      ProcessRegistry.bulk_insert(arg.hub_id, children_formatted)

      local_node = node()

      # Not all nodes should handle the reply_to options or we will end up with multiple replies.
      Enum.each(arg.children, fn {child_id, _, startup_res, {:for_node, for_node, opts}} ->
        if for_node === local_node do
          handle_reply_to(opts, child_id, startup_res, for_node)
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
            start_opts: keyword()
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
                  :start_results
                ]

    @spec handle(t()) :: :ok | {:error, :partitioned}
    def handle(%__MODULE__{} = arg) do
      arg = %__MODULE__{
        arg
        | dist_sup: Name.distributed_supervisor(arg.hub_id),
          sync_strategy: LocalStorage.get(arg.hub_id, :synchronization_strategy),
          redun_strategy: LocalStorage.get(arg.hub_id, :redundancy_strategy),
          dist_strategy: LocalStorage.get(arg.hub_id, :distribution_strategy),
          migr_strategy: LocalStorage.get(arg.hub_id, :migration_strategy)
      }

      case ProcessHub.Service.State.is_partitioned?(arg.hub_id) do
        true ->
          {:error, :partitioned}

        false ->
          %__MODULE__{arg | start_results: start_children(arg)}
          |> update_registry()
          |> handle_migration_callback()
          |> handle_sync_callback()
          |> release_lock()

          :ok
      end
    end

    defp handle_sync_callback(arg) do
      SynchronizationStrategy.propagate(
        arg.sync_strategy,
        arg.hub_id,
        arg.start_results,
        node(),
        :add,
        members: :external
      )

      arg
    end

    defp handle_migration_callback(arg) do
      MigrationStrategy.handle_startup(
        arg.migr_strategy,
        arg.hub_id,
        Enum.map(arg.start_results, fn {child_id, {_, [_, pid]}, _, _} ->
          {child_id, pid}
        end)
      )

      arg
    end

    defp update_registry(arg) do
      Task.Supervisor.async(
        Name.task_supervisor(arg.hub_id),
        SyncHandle,
        :handle,
        [
          %SyncHandle{
            hub_id: arg.hub_id,
            children: arg.start_results
          }
        ]
      )
      |> Task.await()

      arg
    end

    defp release_lock(arg) do
      # Release the event queue lock only when migrating
      # processes rather than regular startup.
      if Keyword.get(arg.start_opts, :migration_add, false) === true do
        State.unlock_event_handler(arg.hub_id)
      end
    end

    defp start_children(arg) do
      HookManager.dispatch_hook(arg.hub_id, Hook.pre_children_start(), arg)

      local_node = node()

      validate_children(arg)
      |> Enum.map(fn child_data ->
        startup_result = child_start_result(arg, child_data, local_node)

        case startup_result do
          {:ok, pid} ->
            format_start_resp(child_data, local_node, pid, startup_result)

          {:error, {:already_started, pid}} ->
            format_start_resp(child_data, local_node, pid, startup_result)

          _ ->
            nil
        end
      end)
      |> Enum.filter(&(&1 !== nil))
    end

    defp format_start_resp(child_data, local_node, pid, startup_result) do
      {
        child_data.child_spec.id,
        {child_data.child_spec, [{local_node, pid}]},
        startup_result,
        {:for_node, local_node,
         [
           {:reply_to, Map.get(child_data, :reply_to, [])},
           {:migration, Map.get(child_data, :migration, false)}
         ]}
      }
    end

    defp child_start_result(arg, child_data, local_node) do
      cid = child_data.child_spec.id

      case DistributedSupervisor.start_child(arg.dist_sup, child_data.child_spec) do
        {:ok, pid} ->
          RedundancyStrategy.handle_post_start(
            arg.redun_strategy,
            arg.dist_strategy,
            cid,
            pid,
            child_data.nodes
          )

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
