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

  @typedoc """
  Coordinator boot-recovery state. `:recovering` means the first orphan reconcile
  round has not completed; `:normal` means it has and is terminal.
  """
  @type recovery_state() :: :recovering | :normal

  @typedoc """
  Parsed `:auto_recovery` config. `enabled?` gates the lifecycle;
  `reconcile_grace_ms` delays the first reconcile round after coordinator start;
  `reconcile_interval_ms` rate-limits subsequent rounds and bounds each blocking
  hook handler; `remote_manifest` is the optional off-cluster declared-list
  adapter (`{module, opts}`).
  """
  @type recovery_config() :: %{
          enabled?: boolean(),
          reconcile_grace_ms: pos_integer(),
          reconcile_interval_ms: pos_integer(),
          remote_manifest: {module(), keyword()} | nil
        }

  @type t() :: %__MODULE__{
          hub_id: atom(),
          procs: %{
            initializer: pid(),
            task_sup: {:via, Registry, {pid(), binary()}},
            dist_sup: {:via, Registry, {pid(), binary()}},
            worker_queue: {:via, Registry, {pid(), binary()}},
            janitor: {:via, Registry, {pid(), binary()}},
            manifest_shipper: {:via, Registry, {pid(), binary()}},
            event_queue: atom()
          },
          storage: %{
            optional(:registry_backend) => {module(), term()},
            optional(:declared_backend) => {module(), term()},
            optional(:declared_path) => String.t(),
            misc: :ets.tid(),
            hook: :ets.tid()
          },
          event_batches: %{nodedown: batch_state(), cluster_join: batch_state()},
          # Per-node membership reconciliation fail-safe timers, keyed by node.
          nodeup_reconcile_timers: %{node() => reference()},
          pending_operations: %{reference() => ProcessHub.Service.RequestManager.t()},
          pending_work_count: non_neg_integer(),
          migration_retry_timer: reference() | {:running, reference()} | nil,
          recovery_state: recovery_state(),
          recovery_config: recovery_config(),
          recovery_normal_waiters: %{GenServer.from() => reference()},
          reconcile_running?: boolean(),
          reconcile_last_at: integer() | nil,
          # The declared-list batch's working manifest, not yet written, and the
          # commands parked behind its write.
          declared_unsynced: map() | nil,
          declared_batch: ProcessHub.Service.Batch.t()
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
    migration_retry_timer: nil,
    recovery_state: :normal,
    recovery_config: %{
      enabled?: false,
      reconcile_grace_ms: 30_000,
      reconcile_interval_ms: 15_000,
      remote_manifest: nil
    },
    recovery_normal_waiters: %{},
    reconcile_running?: false,
    reconcile_last_at: nil,
    declared_unsynced: nil,
    declared_batch: %ProcessHub.Service.Batch{}
  ]

  @doc """
  The hub a worker needs — identity, processes, storage, configuration — with
  the coordinator's transient bookkeeping blanked. That bookkeeping (every
  in-flight operation, the declared-list batch, event batches, waiters) grows
  with the load; handed to the worker queue and copied into every request task
  it made each start cost as much as every start in flight.
  """
  @spec for_workers(t()) :: t()
  def for_workers(%__MODULE__{} = hub) do
    %{
      hub
      | pending_operations: %{},
        declared_unsynced: nil,
        declared_batch: %ProcessHub.Service.Batch{},
        event_batches: %{nodedown: default_batch_state(), cluster_join: default_batch_state()},
        nodeup_reconcile_timers: %{},
        recovery_normal_waiters: %{}
    }
  end
end
