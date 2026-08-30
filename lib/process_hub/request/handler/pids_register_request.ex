defmodule ProcessHub.Request.Handler.PidsRegisterRequest do
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Request.CrossNodeRequest

  defstruct [
    :children_data,
    durable: false
  ]

  def new(children_data, opts \\ []) do
    %__MODULE__{
      children_data: children_data,
      durable: Keyword.get(opts, :durable, false)
    }
  end

  defimpl CrossNodeRequest, for: __MODULE__ do
    alias ProcessHub.Request.Handler.PidsRegisterRequest

    @impl true
    def handle(%PidsRegisterRequest{} = request, hub) do
      ProcessRegistry.bulk_insert(
        hub.hub_id,
        request.children_data,
        hook_storage: hub.storage.hook,
        durable: request.durable
      )
    end
  end
end
