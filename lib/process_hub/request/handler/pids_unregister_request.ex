defmodule ProcessHub.Request.Handler.PidsUnregisterRequest do
  alias ProcessHub.Request.CrossNodeRequest
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

  defimpl CrossNodeRequest, for: __MODULE__ do
    alias ProcessHub.Request.Handler.PidsUnregisterRequest

    @impl true
    def handle(%PidsUnregisterRequest{} = request, hub) do
      ProcessRegistry.bulk_delete(
        hub.hub_id,
        request.removable_cid_nodes,
        hook_storage: hub.storage.hook
      )
    end
  end
end
