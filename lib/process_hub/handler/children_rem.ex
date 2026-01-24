defmodule ProcessHub.Handler.ChildrenRem do
  @moduledoc false

  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Distributor
  alias ProcessHub.StopChildrenRequest
  alias ProcessHub.StopChildrenRequest.NodeStopRequest
  alias ProcessHub.Service.ProcessRegistry

  use Task

  defmodule StopHandle do
    @moduledoc """
    Handler for stopping child processes.
    """

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
      case ProcessHub.Service.State.is_partitioned?(arg.hub) do
        true ->
          {:error, :partitioned}

        false ->
          arg
          |> terminate_children()
          |> send_responses()

          :ok
      end
    end

    defp terminate_children(%__MODULE__{} = arg) do
      sync_strategy = Storage.get(arg.hub.storage.misc, StorageKey.strsyn())

      cids =
        Enum.reduce(arg.children, [], fn child_data, cids ->
          [child_data.child_id | cids]
        end)

      Distributor.children_terminate(arg.hub, cids, sync_strategy)
    end

    defp send_responses(arg) do
      # Build node response from post_stop_results
      results = StopChildrenRequest.build_node_response(arg.children)

      # Send response to coordinator via the new pattern
      stop_opts = effective_stop_opts(arg)
      StopChildrenRequest.send_response_to_coordinator(stop_opts, results)

      arg
    end

    # Get stop_opts from either the NodeStopRequest or the legacy stop_opts field
    defp effective_stop_opts(%__MODULE__{node_stop_request: %NodeStopRequest{} = req}) do
      NodeStopRequest.to_stop_opts(req)
    end

    defp effective_stop_opts(%__MODULE__{stop_opts: opts}) when is_list(opts), do: opts
    defp effective_stop_opts(_), do: []
  end
end
