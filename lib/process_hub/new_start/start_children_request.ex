defmodule ProcessHub.StartChildrenRequest do
  alias ProcessHub.Service.Dispatcher


  @type t() :: %__MODULE__{
          transaction_id: reference(),
          hub_id: ProcessHub.hub_id(),
          nodes_data: [{node(), [map()]}],
          child_specs: [ProcessHub.child_spec()],
          sub_requests: [NodeStartRequest.t()],
          future: ProcessHub.Future.t() | nil,
          options: keyword()
        }
  defstruct [
    :transaction_id,
    :hub_id,
    nodes_data: [],
    child_specs: [],
    sub_requests: [],
    future: nil,
    options: []
  ]

  defmodule NodeStartRequest do
    defstruct [
      :node,
      :children,
      :start_results,
      :caller,
      status: :pending
    ]
  end

  def new(hub, child_specs, mappings, opts) do
    ref = make_ref()

    future = %ProcessHub.Future{
      future_resolver: {node(), hub.hub_id},
      timeout: Keyword.get(opts, :timeout),
      ref: ref
    }

    %__MODULE__{
      transaction_id: make_ref(),
      hub_id: hub.hub_id,
      child_specs: child_specs,
      nodes_data: mappings,
      future: future,
      sub_requests: [],
      options: opts
    }
  end

  @spec compose_sub_requests(t()) :: {:ok, t()} | {:error, :no_children}
  def compose_sub_requests(%__MODULE__{nodes_data: []} = _request) do
    {:error, :no_children}
  end

  def compose_sub_requests(%__MODULE__{hub_id: hub_id, nodes_data: mappings, options: opts} = request) do
    sub_requests =
      Enum.map(mappings, fn {node, children} ->
        %NodeStartRequest{
          node: node,
          children: children,
          status: :dispatched
        }
      end)

    Dispatcher.children_start(hub_id, mappings, opts)

    {:ok, %{request | sub_requests: sub_requests}}
  end
end
