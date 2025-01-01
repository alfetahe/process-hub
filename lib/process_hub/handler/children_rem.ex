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
                child_id: ProcessHub.child_id()
              }
            ],
            dist_sup: atom(),
            sync_strategy: SynchronizationStrategy.t(),
            stop_opts: keyword()
          }

    @enforce_keys [
      :hub_id,
      :children,
      :stop_opts
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
          cids =
            Enum.reduce(arg.children, [], fn child_data, cids ->
              [child_data.child_id | cids]
            end)

          Distributor.children_terminate(
            arg.hub_id,
            cids,
            arg.sync_strategy,
            arg.stop_opts
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
              {ProcessHub.child_id(), :ok | {:error, :not_found}}
            ],
            node: node(),
            stop_opts: keyword()
          }

    @enforce_keys [
      :hub_id,
      :children,
      :node,
      :stop_opts
    ]
    defstruct @enforce_keys

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = args) do
      children_nodes =
        Enum.map(args.children, fn {child_id, _, _} ->
          {child_id, [args.node]}
        end)
        |> Map.new()

      ProcessRegistry.bulk_delete(args.hub_id, children_nodes)
      send_collect_results(args.children, args.stop_opts)

      :ok
    end

    defp send_collect_results(post_stop_results, stop_opts) do
      reply_to = Keyword.get(stop_opts, :reply_to, nil)
      local_node = node()

      # Each node sends only their own child process startup results.
      filtered_data =
        Enum.filter(post_stop_results, fn {_cid, _result, node} ->
          node === local_node
        end)

      if reply_to do
        Enum.each(reply_to, fn respondent ->
          send(respondent, {:collect_stop_results, filtered_data, local_node})
        end)
      end
    end
  end
end
