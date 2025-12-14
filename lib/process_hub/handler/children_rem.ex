defmodule ProcessHub.Handler.ChildrenRem do
  @moduledoc false

  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Distributor
  alias ProcessHub.StopChildrenRequest
  alias ProcessHub.StopChildrenRequest.NodeStopRequest
  alias ProcessHub.Hub

  use Task

  defmodule StopHandle do
    @moduledoc """
    Handler for stopping child processes.
    """

    alias ProcessHub.Service.Storage
    alias ProcessHub.Constant.StorageKey
    alias ProcessHub.Service.Distributor
    alias ProcessHub.StopChildrenRequest.NodeStopRequest

    @type t :: %__MODULE__{
            children: [
              %{
                child_id: ProcessHub.child_id()
              }
            ],
            hub: ProcessHub.Hub.t(),
            stop_opts: keyword() | nil,
            node_stop_request: NodeStopRequest.t() | nil
          }

    @enforce_keys [
      :children,
      :hub
    ]
    defstruct [:children, :hub, :stop_opts, :node_stop_request]

    @spec handle(t()) :: :ok | {:error, :partitioned}
    def handle(%__MODULE__{} = arg) do
      sync_strategy = Storage.get(arg.hub.storage.misc, StorageKey.strsyn())

      case ProcessHub.Service.State.is_partitioned?(arg.hub) do
        true ->
          {:error, :partitioned}

        false ->
          cids =
            Enum.reduce(arg.children, [], fn child_data, cids ->
              [child_data.child_id | cids]
            end)

          # Use effective_stop_opts to get opts from either new request or legacy opts
          stop_opts = effective_stop_opts(arg)

          Distributor.children_terminate(
            arg.hub,
            cids,
            sync_strategy,
            stop_opts
          )

          :ok
      end
    end

    # Get stop_opts from either the NodeStopRequest or the legacy stop_opts field
    defp effective_stop_opts(%__MODULE__{node_stop_request: %NodeStopRequest{} = req}) do
      NodeStopRequest.to_stop_opts(req)
    end

    defp effective_stop_opts(%__MODULE__{stop_opts: opts}) when is_list(opts), do: opts
    defp effective_stop_opts(_), do: []
  end

  defmodule SyncHandle do
    @moduledoc """
    Handler for synchronizing stopped child processes.
    """

    alias ProcessHub.Service.ProcessRegistry
    alias ProcessHub.StopChildrenRequest
    alias ProcessHub.StopChildrenRequest.NodeStopRequest

    @type t :: %__MODULE__{
            hub: Hub.t(),
            children: [
              {ProcessHub.child_id(), :ok | {:error, :not_found}, node()}
            ],
            node: node(),
            stop_opts: keyword() | nil,
            node_stop_request: NodeStopRequest.t() | nil
          }

    @enforce_keys [
      :hub,
      :children,
      :node
    ]
    defstruct [:hub, :children, :node, :stop_opts, :node_stop_request]

    @spec handle(t()) :: :ok
    def handle(%__MODULE__{} = args) do
      children_nodes =
        Enum.map(args.children, fn {child_id, _, _} ->
          {child_id, [args.node]}
        end)
        |> Map.new()

      if !Enum.empty?(children_nodes) do
        ProcessRegistry.bulk_delete(args.hub.hub_id, children_nodes,
          hook_storage: args.hub.storage.hook
        )
      end

      # Build node response from post_stop_results
      results = StopChildrenRequest.build_node_response(args.children)

      # Send response to coordinator via the new pattern
      stop_opts = effective_stop_opts(args)
      StopChildrenRequest.send_response_to_coordinator(stop_opts, results)

      # Also send legacy results for backward compatibility
      send_legacy_results(results, stop_opts)

      :ok
    end

    # Get stop_opts from either the NodeStopRequest or the legacy stop_opts field
    defp effective_stop_opts(%__MODULE__{node_stop_request: %NodeStopRequest{} = req}) do
      NodeStopRequest.to_stop_opts(req)
    end

    defp effective_stop_opts(%__MODULE__{stop_opts: opts}) when is_list(opts), do: opts
    defp effective_stop_opts(_), do: []

    # Send legacy results for backward compatibility
    defp send_legacy_results(receiver_data, stop_opts) do
      reply_to = Keyword.get(stop_opts, :reply_to, nil)
      local_node = node()

      # Only send response if we have actual results from this node
      # This prevents nodes from sending empty responses for other nodes' results
      if reply_to && !Enum.empty?(receiver_data) do
        Enum.each(reply_to, fn respondent ->
          send(respondent, {:collect_stop_results, receiver_data, local_node})
        end)
      end
    end
  end
end
