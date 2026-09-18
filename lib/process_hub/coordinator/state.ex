defmodule ProcessHub.Coordinator.State do
  @moduledoc """
  The coordinator's state: the hub's fixed parts (`ProcessHub.Hub`) and the
  bookkeeping that changes as the coordinator handles messages.
  """

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

  @type t() :: %__MODULE__{
          hub: ProcessHub.Hub.t(),
          event_batches: %{
            nodedown: batch_state(),
            cluster_leave: batch_state(),
            cluster_join: batch_state()
          },
          # Per-node membership reconciliation fail-safe timers, keyed by node.
          nodeup_reconcile_timers: %{node() => reference()},
          pending_operations: %{reference() => ProcessHub.Service.RequestManager.t()},
          pending_work_count: non_neg_integer(),
          migration_retry_timer: reference() | {:running, reference()} | nil,
          recovery_state: recovery_state(),
          recovery_normal_waiters: %{GenServer.from() => reference()},
          reconcile_running?: boolean(),
          reconcile_last_at: integer() | nil,
          cluster_settled?: boolean(),
          registry_delivered_by: MapSet.t(node()),
          # The declared-list batch's working manifest, not yet written, and the
          # commands parked behind its write.
          declared_unsynced: map() | nil,
          declared_batch: ProcessHub.Service.Batch.t()
        }

  @default_batch %{nodes: [], timer_ref: nil, started_at: nil}

  @doc "Returns the default event batch state."
  @spec default_batch_state() :: batch_state()
  def default_batch_state, do: @default_batch

  defstruct [
    :hub,
    event_batches: %{
      nodedown: @default_batch,
      cluster_leave: @default_batch,
      cluster_join: @default_batch
    },
    nodeup_reconcile_timers: %{},
    pending_operations: %{},
    pending_work_count: 0,
    migration_retry_timer: nil,
    recovery_state: :normal,
    recovery_normal_waiters: %{},
    reconcile_running?: false,
    reconcile_last_at: nil,
    cluster_settled?: false,
    registry_delivered_by: MapSet.new(),
    declared_unsynced: nil,
    declared_batch: %ProcessHub.Service.Batch{}
  ]
end
