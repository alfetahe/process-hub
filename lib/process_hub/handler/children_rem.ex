defmodule ProcessHub.Handler.ChildrenRem do
  @moduledoc false

  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy

  use Task

  defmodule StopHandle do
    @moduledoc """
    Handler for stopping child processes.
    """

    @type t :: %__MODULE__{
            hub_id: ProcessHub.hub_id(),
            children: [
              %{
                child_id: ProcessHub.child_id(),
                reply_to: ProcessHub.reply_to()
              }
            ],
            dist_sup: ProcessHub.DistributedSupervisor.pname(),
            sync_strategy: SynchronizationStrategy.t()
          }

    @enforce_keys [
      :hub_id,
      :children,
      :dist_sup,
      :sync_strategy
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok | {:error, :partitioned}
    def handle(%__MODULE__{} = args) do
      case ProcessHub.Service.State.is_partitioned?(args.hub_id) do
        true ->
          {:error, :partitioned}

        false ->
          local_node = node()

          stopped_children =
            Enum.map(args.children, fn child_data ->
              terminate_result =
                DistributedSupervisor.terminate_child(args.dist_sup, child_data.child_id)

              {child_data.child_id, {terminate_result, Map.get(child_data, :reply_to, [])}}
            end)

          SynchronizationStrategy.propagate(
            args.sync_strategy,
            args.hub_id,
            stopped_children,
            local_node,
            :rem
          )

          :ok
      end
    end
  end

  defmodule SyncHandle do
    @moduledoc """
    Handler for synchronizing stopped child processes.
    """

    alias ProcessHub.Service.ProcessRegistry

    @type t :: %__MODULE__{
            hub_id: ProcessHub.hub_id(),
            children: [
              {
                ProcessHub.child_id(),
                {
                  :ok | {:error, :not_found},
                  ProcessHub.reply_to()
                }
              }
            ],
            node: node()
          }

    @enforce_keys [
      :hub_id,
      :children,
      :node
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = args) do
      children_nodes =
        Enum.map(args.children, fn {child_id, _} ->
          {child_id, [args.node]}
        end)
        |> Map.new()

      ProcessRegistry.bulk_delete(args.hub_id, children_nodes)

      local_node = node()

      Enum.each(args.children, fn {child_id, {stop_res, reply_to}} ->
        if is_list(reply_to) do
          Enum.each(reply_to, fn respondent ->
            send(respondent, {:child_stop_resp, child_id, stop_res, local_node})
          end)
        end
      end)

      :ok
    end
  end
end
