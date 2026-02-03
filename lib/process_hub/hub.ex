defmodule ProcessHub.Hub do
  @typedoc """
  State for batched event handling.
  - `nodes`: List of nodes accumulated in the batch
  - `timer_ref`: Reference to the timer that will trigger batch processing
  """
  @type batch_state() :: %{
          nodes: [node()],
          timer_ref: reference() | nil
        }

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
          },
          event_batches: %{
            nodedown: batch_state(),
            cluster_join: batch_state()
          },
          pending_operations: %{reference() => ProcessHub.Service.RequestManager.t()}
        }

  @doc """
  Returns the default event batch state.
  """
  def default_batch_state do
    %{nodes: [], timer_ref: nil}
  end

  defstruct [
    :hub_id,
    :procs,
    :storage,
    event_batches: %{
      nodedown: %{nodes: [], timer_ref: nil},
      cluster_join: %{nodes: [], timer_ref: nil}
    },
    pending_operations: %{}
  ]
end
