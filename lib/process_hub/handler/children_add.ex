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

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = args) do
      local_node = node()

      started_children =
        validate_children(args.hub_id, args.children, args.redun_strategy, args.hash_ring)
        |> Enum.map(fn child_data ->
          cid = child_data.child_spec.id

          startup_result =
            case DistributedSupervisor.start_child(args.dist_sup, child_data.child_spec) do
              {:ok, pid} ->
                RedundancyStrategy.handle_post_start(
                  args.redun_strategy,
                  args.hash_ring,
                  cid,
                  pid
                )

                {:ok, pid}

              any ->
                Map.get(child_data, :reply_to, [])
                |> Dispatcher.reply_respondents(:child_start_resp, cid, any, local_node)
            end

          case startup_result do
            {:ok, pid} ->
              {
                child_data.child_spec.id,
                {child_data.child_spec, [{local_node, pid}]},
                {Map.get(child_data, :reply_to, []), startup_result}
              }

            _ ->
              nil
          end
        end)
        |> Enum.filter(&(&1 !== nil))

      SynchronizationStrategy.propagate(
        args.sync_strategy,
        args.hub_id,
        started_children,
        local_node,
        :add
      )

      :ok
    end

    defp validate_children(hub_id, children, redun_strategy, hash_ring) do
      # Check if the child belongs to this node.
      local_node = node()

      Enum.reduce(children, [], fn %{child_id: child_id} = child_data, acc ->
        nodes =
          ProcessHub.Strategy.Redundancy.Base.belongs_to(redun_strategy, hash_ring, child_id)

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
        Enum.map(args.children, fn {child_id, child_spec, _} ->
          {child_id, child_spec}
        end)
        |> Map.new()

      ProcessRegistry.bulk_insert(args.hub_id, children_formatted)

      local_node = node()

      Enum.each(args.children, fn {child_id, _, {reply_to, startup_res}} ->
        Dispatcher.reply_respondents(
          reply_to,
          :child_start_resp,
          child_id,
          startup_res,
          local_node
        )
      end)
    end
  end
end
