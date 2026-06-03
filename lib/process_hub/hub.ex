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
  `recovery_window_ms` is the peer-handshake window;
  `replay_timeout_ms` caps the replay loop; `recovery_timeout_ms`
  caps the cluster-event queue gate.
  """
  @type recovery_config() :: %{
          enabled?: boolean(),
          recovery_window_ms: pos_integer(),
          replay_timeout_ms: pos_integer(),
          recovery_timeout_ms: pos_integer()
        }

  @typedoc """
  Marker config. `enabled?` is the gate switch; `path` holds the
  *resolved absolute* marker path after coordinator init (or `nil`
  while disabled).
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
          recovery_window_timer: reference() | nil,
          recovery_peers: %{node() => recovery_state()},
          recovery_marker: recovery_marker(),
          recovery_event_queue: [term()],
          recovery_timeout_timer: reference() | nil,
          recovery_restart_signal_sent?: boolean()
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
      recovery_window_ms: 10_000,
      replay_timeout_ms: 60_000,
      recovery_timeout_ms: 30_000
    },
    recovery_window_timer: nil,
    recovery_peers: %{},
    recovery_marker: %{enabled?: false, path: nil},
    recovery_event_queue: [],
    recovery_timeout_timer: nil,
    recovery_restart_signal_sent?: false
  ]
end
