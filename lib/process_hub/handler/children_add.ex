defmodule ProcessHub.Handler.ChildrenAdd do
  @moduledoc false

  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Service.Dispatcher

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
            hash_ring: :hash_ring.ring(),
            dist_sup: ProcessHub.DistributedSupervisor.pname(),
            sync_strategy: SynchronizationStrategy.t(),
            redun_strategy: RedundancyStrategy.t()
          }

    @enforce_keys [
      :hub_id,
      :children,
      :hash_ring,
      :dist_sup,
      :sync_strategy,
      :redun_strategy
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok | {:error, :partitioned}
    def handle(%__MODULE__{} = args) do
      case ProcessHub.Service.State.is_partitioned?(args.hub_id) do
        true ->
          {:error, :partitioned}

        false ->
          start_results = start_children(args)

          SynchronizationStrategy.propagate(
            args.sync_strategy,
            args.hub_id,
            start_results,
            node(),
            :add
          )

          :ok
      end
    end

    defp start_children(args) do
      local_node = node()

      validate_children(args.hub_id, args.children, args.redun_strategy, args.hash_ring)
      |> Enum.map(fn child_data ->
        startup_result = child_start_result(args, child_data, local_node)

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

    defp child_start_result(args, child_data, local_node) do
      cid = child_data.child_spec.id

      case DistributedSupervisor.start_child(args.dist_sup, child_data.child_spec) do
        {:ok, pid} ->
          RedundancyStrategy.handle_post_start(
            args.redun_strategy,
            args.hash_ring,
            cid,
            pid
          )

          {:ok, pid}

        {:error, {:already_started, pid}} ->
          {:error, {:already_started, pid}}

        any ->
          Map.get(child_data, :reply_to, [])
          |> Dispatcher.reply_respondents(:child_start_resp, cid, any, local_node)
      end
    end

    defp validate_children(hub_id, children, redun_strategy, hash_ring) do
      # Check if the child belongs to this node.
      local_node = node()

      Enum.reduce(children, [], fn %{child_id: child_id} = child_data, acc ->
        nodes =
          ProcessHub.Strategy.Redundancy.Base.belongs_to(redun_strategy, hash_ring, child_id)

        # Recheck if the node that is supposed to be started on local node is
        # assigned to this node or not. If not then forward to the correct node.
        #
        # These cases can happen when multiple nodes are added to the cluster
        # at the same time.
        case Enum.member?(nodes, local_node) do
          true ->
            [child_data | acc]

          false ->
            forward_child(hub_id, child_data, nodes)
            acc
        end
      end)
    end

    defp forward_child(hub_id, child_data, parent_nodes) do
      parent_node = Enum.at(parent_nodes, 0)

      case is_atom(parent_node) do
        true -> Dispatcher.children_start(hub_id, [{parent_node, [child_data]}])
        false -> nil
      end
    end
  end

  defmodule SyncHandle do
    @moduledoc """
    Handler for synchronizing added child processes.
    """

    alias ProcessHub.Service.ProcessRegistry
    alias ProcessHub.Service.HookManager
    alias ProcessHub.Constant.Hook

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
    def handle(%__MODULE__{} = args) do
      children_formatted =
        Enum.map(args.children, fn {child_id, {_child_spec, _child_nodes} = cn, _, _} ->
          {child_id, cn}
        end)
        |> Map.new()

      ProcessRegistry.bulk_insert(args.hub_id, children_formatted)

      local_node = node()

      Enum.each(args.children, fn {child_id, _, startup_res, {:for_node, for_node, opts}} ->
        if for_node === local_node do
          handle_reply_to(opts, child_id, startup_res, for_node)
          handle_migration(opts, args.hub_id, child_id, for_node)
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
