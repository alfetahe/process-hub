defmodule ProcessHub.Request.Handler.PidsUnregisterRequest do
  alias ProcessHub.Request.CrossNodeRequest
  alias ProcessHub.Service.ProcessRegistry

  @typedoc """
  `on_empty` carries the originating node's intent for a row left with no node
  entries, so every peer resolves the row the same way it did.
  """
  @type t :: %__MODULE__{
          removable_cid_nodes: [
            {ProcessHub.child_id(), [node()]}
          ],
          on_empty: :churn | :keep | :delete
        }
  defstruct [
    :removable_cid_nodes,
    on_empty: :churn
  ]

  def new(removable_cid_nodes, opts \\ []) do
    %__MODULE__{
      removable_cid_nodes: removable_cid_nodes,
      on_empty: Keyword.get(opts, :on_empty, :churn)
    }
  end

  defimpl CrossNodeRequest, for: __MODULE__ do
    alias ProcessHub.Request.Handler.PidsUnregisterRequest

    @impl true
    def handle(%PidsUnregisterRequest{} = request, hub) do
      ProcessRegistry.bulk_delete(
        hub.hub_id,
        request.removable_cid_nodes,
        hook_storage: hub.storage.hook,
        on_empty: request.on_empty
      )
    end
  end
end
