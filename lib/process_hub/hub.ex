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

  @typedoc """
  The coordinator's boot-recovery state (when `:auto_recovery` is enabled).

  See `ProcessHub.Constant.RecoveryState`.
  """
  @type recovery_state() :: :recovery_pending | :recovering | :normal

  @typedoc """
  Configuration parsed from `ProcessHub.t().auto_recovery`.

  - `enabled?` — whether the lifecycle is active for this hub.
  - `recovery_window_ms` — how long to wait in `:recovery_pending` for a
    peer to report `:normal` before falling back to local replay.
  - `replay_timeout_ms` — safety timeout on `:recovering`. Coordinator
    transitions to `:normal` regardless when it elapses; replay continues
    in the background.
  """
  @type recovery_config() :: %{
          enabled?: boolean(),
          recovery_window_ms: pos_integer(),
          replay_timeout_ms: pos_integer()
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
            optional(:registry_backend) => {module(), term()},
            misc: :ets.tid(),
            hook: :ets.tid()
          },
          event_batches: %{
            nodedown: batch_state(),
            cluster_join: batch_state()
          },
          pending_operations: %{reference() => ProcessHub.Service.RequestManager.t()},
          pending_work_count: non_neg_integer(),
          recovery_state: recovery_state(),
          recovery_config: recovery_config(),
          recovery_window_timer: reference() | nil,
          recovery_peers: %{node() => recovery_state()}
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
    pending_operations: %{},
    pending_work_count: 0,
    recovery_state: :normal,
    recovery_config: %{enabled?: false, recovery_window_ms: 10_000, replay_timeout_ms: 60_000},
    recovery_window_timer: nil,
    recovery_peers: %{}
  ]
end
