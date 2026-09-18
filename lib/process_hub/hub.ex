defmodule ProcessHub.Hub do
  @moduledoc """
  The parts of a hub that are fixed when it starts: its id, its processes, its
  storage and its parsed `:auto_recovery` config.

  A running hub is stored before any of its processes start, so any process
  reads it with `get/1` without messaging the coordinator. The coordinator's
  changing bookkeeping lives in `ProcessHub.Coordinator.State`.
  """

  @typedoc """
  Parsed `:auto_recovery` config. `enabled?` gates the lifecycle;
  `reconcile_grace_ms` caps the wait for the first reconcile round after
  coordinator start; `cluster_settle_ms` is how long silence from the cluster
  counts as "this node is alone"; `reconcile_interval_ms` rate-limits subsequent
  rounds and bounds each blocking hook handler; `remote_manifest` is the optional
  off-cluster declared-list adapter (`{module, opts}`).
  """
  @type recovery_config() :: %{
          enabled?: boolean(),
          reconcile_grace_ms: pos_integer(),
          reconcile_interval_ms: pos_integer(),
          cluster_settle_ms: non_neg_integer(),
          remote_manifest: {module(), keyword()} | nil
        }

  @type t() :: %__MODULE__{
          hub_id: atom(),
          procs: %{
            initializer: pid(),
            system_registry: atom(),
            event_queue: atom(),
            process_registry: GenServer.name(),
            dist_sup: GenServer.name(),
            task_sup: GenServer.name(),
            worker_queue: GenServer.name(),
            bootstrap_worker: GenServer.name(),
            janitor: GenServer.name(),
            manifest_shipper: GenServer.name()
          },
          storage: %{
            optional(:registry_backend) => {module(), term()},
            optional(:declared_backend) => {module(), term()},
            optional(:declared_path) => String.t(),
            misc: :ets.tid(),
            hook: :ets.tid()
          },
          recovery_config: recovery_config()
        }

  defstruct [:hub_id, :procs, :storage, :recovery_config]

  @doc "Stores `hub` under its `hub_id`. The only writer of the stored hub."
  @spec put(t()) :: :ok
  def put(%__MODULE__{hub_id: hub_id} = hub), do: :persistent_term.put({__MODULE__, hub_id}, hub)

  @doc "Returns the running hub `hub_id`, or `nil` when it is not running."
  @spec get(atom()) :: t() | nil
  def get(hub_id), do: :persistent_term.get({__MODULE__, hub_id}, nil)

  @doc "Removes the stored hub `hub_id`."
  @spec delete(atom()) :: :ok
  def delete(hub_id) do
    :persistent_term.erase({__MODULE__, hub_id})
    :ok
  end
end
