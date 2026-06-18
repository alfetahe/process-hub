defmodule ProcessHub.Hub do
  @typedoc """
  Per-event batch state: pending nodes, debounce timer ref, and the monotonic
  ms at which the current window opened — used to cap the total wait so a
  sustained event stream cannot starve the batch.
  """
  @type batch_state() :: %{
          nodes: [node()],
          timer_ref: reference() | nil,
          started_at: integer() | nil
        }

  @typedoc "Coordinator boot-recovery state (see `ProcessHub.Constant.RecoveryState`)."
  @type recovery_state() :: :recovery_pending | :recovering | :normal

  @typedoc """
  Parsed `:auto_recovery` config. `enabled?` gates the lifecycle;
  `replay_timeout_ms` caps the replay loop; `recovery_timeout_ms`
  caps the cluster-event queue gate; `marker_path` is the operator
  override for the marker file location (`nil` resolves to the default).
  """
  @type recovery_config() :: %{
          enabled?: boolean(),
          replay_timeout_ms: pos_integer(),
          recovery_timeout_ms: pos_integer(),
          marker_path: nil | String.t()
        }

  @typedoc """
  Resolved marker state derived from `:auto_recovery`. `enabled?` mirrors
  the recovery config; `path` holds the *resolved absolute* marker path
  after coordinator init (or `nil` while disabled).
  """
  @type recovery_marker() :: %{enabled?: boolean(), path: nil | String.t()}

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
          event_batches: %{nodedown: batch_state(), cluster_join: batch_state()},
          # Per-node membership reconciliation fail-safe timers, keyed by node.
          nodeup_reconcile_timers: %{node() => reference()},
          pending_operations: %{reference() => ProcessHub.Service.RequestManager.t()},
          pending_work_count: non_neg_integer(),
          recovery_state: recovery_state(),
          recovery_config: recovery_config(),
          recovery_marker: recovery_marker(),
          recovery_event_queue: [term()],
          recovery_timeout_timer: reference() | nil,
          recovery_restart_signal_sent?: boolean(),
          recovery_normal_waiters: %{GenServer.from() => reference()}
        }

  @doc "Returns the default event batch state."
  def default_batch_state, do: %{nodes: [], timer_ref: nil, started_at: nil}

  defstruct [
    :hub_id,
    :procs,
    :storage,
    event_batches: %{
      nodedown: %{nodes: [], timer_ref: nil, started_at: nil},
      cluster_join: %{nodes: [], timer_ref: nil, started_at: nil}
    },
    nodeup_reconcile_timers: %{},
    pending_operations: %{},
    pending_work_count: 0,
    recovery_state: :normal,
    recovery_config: %{
      enabled?: false,
      replay_timeout_ms: 60_000,
      recovery_timeout_ms: 30_000,
      marker_path: nil
    },
    recovery_marker: %{enabled?: false, path: nil},
    recovery_event_queue: [],
    recovery_timeout_timer: nil,
    recovery_restart_signal_sent?: false,
    recovery_normal_waiters: %{}
  ]
end
