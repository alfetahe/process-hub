defmodule ProcessHub.Hub do
  @type t() :: %__MODULE__{
          hub_id: atom(),
          managers: %{
            task_supervisor: {:via, Registry, {pid(), binary()}},
            distributed_supervisor: {:via, Registry, {pid(), binary()}},
            event_queue: atom()
          },
          storage: %{
            local: reference(),
            remote: reference()
          }
        }

  defstruct [
    :hub_id,
    :managers,
    :storage
  ]
end
