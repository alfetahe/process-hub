defmodule ProcessHub.Request.Handler.PidsRegisterHandler do
  alias ProcessHub.Request.RequestHandler
  alias ProcessHub.Service.ProcessRegistry

  defstruct [
    :children_data
  ]

  def new(children_data) do
    %__MODULE__{
      children_data: children_data
    }
  end

  defimpl RequestHandler, for: __MODULE__ do
    alias ProcessHub.Request.Handler.PidsRegisterHandler

    @impl true
    def preprocess(%PidsRegisterHandler{} = request_handler, _hub) do
      # TODO: do we need any validations here?
      request_handler
    end

    @impl true
    def handle(%PidsRegisterHandler{} = request_handler, hub) do
      ProcessRegistry.bulk_insert(
        hub.hub_id,
        request_handler.children_data,
        hook_storage: hub.storage.hook
      )
    end
  end
end
