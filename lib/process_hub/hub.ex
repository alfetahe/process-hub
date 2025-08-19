defmodule ProcessHub.Hub do
  @type t() :: %__MODULE__{
          hub_id: atom(),
          managers: %{
            initializer: pid(),
            task_supervisor: {:via, Registry, {pid(), binary()}},
            distributed_supervisor: {:via, Registry, {pid(), binary()}},
            worker_queue: {:via, Registry, {pid(), binary()}},
            janitor: {:via, Registry, {pid(), binary()}},
            event_queue: atom()
          },
          storage: %{
            misc: reference(),
            hook: reference()
          }
        }

  defstruct [
    :hub_id,
    :managers,
    :storage
  ]
end
