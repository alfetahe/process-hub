defmodule ProcessHub.Request.Handler.PidsRegisterRequest do
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Request.CrossNodeRequest

  defstruct [
    :children_data
  ]

  def new(children_data) do
    %__MODULE__{
      children_data: children_data
    }
  end

  defimpl CrossNodeRequest, for: __MODULE__ do
    alias ProcessHub.Request.Handler.PidsRegisterRequest

    @impl true
    def handle(%PidsRegisterRequest{} = request, hub) do
      ProcessRegistry.bulk_insert(
        hub.hub_id,
        request.children_data,
        hook_storage: hub.storage.hook
      )
    end
  end
end
