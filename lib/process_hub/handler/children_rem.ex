defmodule ProcessHub.Handler.ChildrenRem do
  @moduledoc false

  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Utility.Name
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Distributor

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
            dist_sup: atom(),
            sync_strategy: SynchronizationStrategy.t()
          }

    @enforce_keys [
      :hub_id,
      :children
    ]
    defstruct @enforce_keys ++
                [
                  :dist_sup,
                  :sync_strategy
                ]

    @spec handle(t()) :: :ok | {:error, :partitioned}
    def handle(%__MODULE__{} = arg) do
      arg = %__MODULE__{
        arg
        | dist_sup: Name.distributed_supervisor(arg.hub_id),
          sync_strategy: Storage.get(Name.local_storage(arg.hub_id), StorageKey.strsyn())
      }

      case ProcessHub.Service.State.is_partitioned?(arg.hub_id) do
        true ->
          {:error, :partitioned}

        false ->
          {cids, reply_opts} =
            Enum.reduce(arg.children, {[], []}, fn child_data, {cids, reply_opts} ->
              cid = child_data.child_id

              {
                [cid | cids],
                [{cid, Map.get(child_data, :reply_to, [])} | reply_opts]
              }
            end)

          Distributor.children_terminate(arg.hub_id, cids, arg.sync_strategy, reply_opts)

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
