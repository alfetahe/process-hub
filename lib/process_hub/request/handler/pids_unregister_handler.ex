defmodule ProcessHub.Request.Handler.PidsUnregisterHandler do
  alias ProcessHub.Request.RequestHandler
  alias ProcessHub.Service.ProcessRegistry

  @type t :: %__MODULE__{
          removable_cid_nodes: [
            {ProcessHub.child_id(), [node()]}
          ]
        }
  defstruct [
    :removable_cid_nodes
  ]

  def new(removable_cid_nodes) do
    %__MODULE__{
      removable_cid_nodes: removable_cid_nodes
    }
  end

  defimpl RequestHandler, for: __MODULE__ do
    alias ProcessHub.Request.Handler.PidsUnregisterHandler

    @impl true
    def preprocess(%PidsUnregisterHandler{} = request_handler, _hub) do
      # TODO: do we need any validations here?
      request_handler
    end

    @impl true
    def handle(%PidsUnregisterHandler{} = request_handler, hub) do
      ProcessRegistry.bulk_delete(
        hub.hub_id,
        request_handler.removable_cid_nodes,
        hook_storage: hub.storage.hook
      )
    end
  end
end
