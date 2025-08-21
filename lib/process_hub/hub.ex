defmodule ProcessHub.Hub do
  @type t() :: %__MODULE__{
          hub_id: atom(),
          procs: %{
            initializer: pid(),
            task_sup: {:via, Registry, {pid(), binary()}},
            dist_sup: {:via, Registry, {pid(), binary()}},
            worker_queue: {:via, Registry, {pid(), binary()}},
            janitor: {:via, Registry, {pid(), binary()}},
            event_queue: atom()
          },
          storage: %{
            misc: :ets.tid(),
            hook: :ets.tid()
          }
        }
  defstruct [
    :hub_id,
    :procs,
    :storage
  ]
end
