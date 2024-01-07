defmodule ProcessHub.Handler.ChildrenAdd do
  @moduledoc false

  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook

  use Task

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
            dist_sup: ProcessHub.DistributedSupervisor.pname(),
            sync_strategy: SynchronizationStrategy.t(),
            redun_strategy: RedundancyStrategy.t(),
            dist_strategy: DistributionStrategy.t(),
            start_opts: keyword()
          }

    @enforce_keys [
      :hub_id,
      :children,
      :dist_sup,
      :sync_strategy,
      :dist_strategy,
      :redun_strategy,
      :start_opts
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok | {:error, :partitioned}
    def handle(%__MODULE__{} = arg) do
      case ProcessHub.Service.State.is_partitioned?(arg.hub_id) do
        true ->
          {:error, :partitioned}

        false ->
          start_results = start_children(arg)

          SynchronizationStrategy.propagate(
            arg.sync_strategy,
            arg.hub_id,
            start_results,
            node(),
            :add
          )

          :ok
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

      Enum.reduce(children, [], fn %{child_id: child_id} = child_data, acc ->
        nodes = DistributionStrategy.belongs_to(dist_strat, hub_id, child_id, replication_factor)

        # Recheck if the node that is supposed to be started on local node is
        # assigned to this node or not. If not then forward to the correct node.
        #
        # These cases can happen when multiple nodes are added to the cluster
        # at the same time.
        case Enum.member?(nodes, local_node) do
          true ->
            [child_data | acc]

          false ->
            forward_child(hub_id, child_data, nodes, start_opts)
            acc
        end
      end)
    end

    defp forward_child(hub_id, child_data, parent_nodes, start_opts) do
      parent_node = Enum.at(parent_nodes, 0)

      case is_atom(parent_node) do
        true -> Dispatcher.children_start(hub_id, [{parent_node, [child_data]}], start_opts)
        false -> nil
      end
    end
  end

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

      Enum.each(arg.children, fn {child_id, _, startup_res, {:for_node, for_node, opts}} ->
        if for_node === local_node do
          handle_reply_to(opts, child_id, startup_res, for_node)
          handle_migration(opts, arg.hub_id, child_id, for_node)
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

    defp handle_migration(opts, hub_id, child_id, local_node) do
      migration = Keyword.get(opts, :migration, false)

      if migration do
        HookManager.dispatch_hook(hub_id, Hook.forwarded_migration(), {child_id, local_node})
      end
    end
  end
end
