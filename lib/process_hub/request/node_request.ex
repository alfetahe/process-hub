defmodule ProcessHub.Request.NodeRequest do
  alias ProcessHub.Hub
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy

  defstruct [
    :distribution_signature,
    :request_handler
  ]

  def new(%Hub{} = hub, request_handler) do
    distribution_signature =
      hub.storage.misc
      |> Storage.get(StorageKey.strdist())
      |> DistributionStrategy.distribution_signature(hub)

    %__MODULE__{
      distribution_signature: distribution_signature,
      request_handler: request_handler
    }
  end
end
