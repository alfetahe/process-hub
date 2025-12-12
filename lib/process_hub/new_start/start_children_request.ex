defmodule ProcessHub.StartChildrenRequest do
  defstruct [
    :transaction_id,
    child_mappings: %{},
    child_specs: [],
    sub_requests: [],
    future: nil,
    options: [],
  ]

  defmodule NodeStartRequest do
    defstruct [
      :node,
      :children,
      :start_results,
      :status,
    ]
  end

  def new(hub, child_specs, mappings, opts) do
    # Compose the future.
    future = %ProcessHub.Future{
      future_resolver: {node(), hub.hub_id},
      timeout: Keyword.get(opts, :timeout),
      ref: ref
    }

    %ProcessHub.StartChildrenRequest{
      transaction_id: make_ref(),
      child_specs: child_specs,
      child_mappings: mappings,
      child_specs: child_specs,
      future: future,
      sub_requests: [],
      options: opts,
    }
  end
end
