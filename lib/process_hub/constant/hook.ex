defmodule ProcessHub.Constant.Hook do
  @moduledoc """
  Defines the list of hooks that can be used to extend the functionality of ProcessHub.
  """

  @doc """
  Hook triggered when a new node has joined the hub cluster and before handling
  the node join event.

  Data: `%{node: node()}`
  """
  @spec pre_node_join() :: atom()
  def pre_node_join(), do: :pre_node_join_hook

  @doc """
  Hook triggered when a new node has joined the hub cluster and after handling
  the node join event.

  Data: `%{node: node()}`
  """
  @spec post_node_join() :: atom()
  def post_node_join(), do: :post_node_join_hook

  @doc """
  Hook triggered when a node has left the hub cluster and before handling
  the node leave event.

  Data: `%{node: node()}`
  """
  @spec pre_node_leave() :: atom()
  def pre_node_leave(), do: :pre_node_leave_hook

  @doc """
  Hook triggered when a node has left the hub cluster and after handling
  the node leave event.

  Data: `%{node: node()}`
  """
  @spec post_node_leave() :: atom()
  def post_node_leave(), do: :post_node_leave_hook

  @doc """
  Hook triggered when a new process is registered in the ProcessHub registry.

  Data: `%{child_id: child_id(), node_pids: [{node(), pid()}]}`
  """
  @spec child_registered() :: atom()
  def child_registered(), do: :child_registered_hook

  @doc """
  Hook triggered when a process is unregistered from the ProcessHub registry.

  Data: `%{child_id: child_id()}`
  """
  @spec child_unregistered() :: atom()
  def child_unregistered(), do: :child_unregistered_hook

  @doc """
  Hook triggered when the migration handler has finished processing.
  This does not indicate whether the migration has completed.

  Data: `%{nodes: [node()], child_specs: [child_spec()]}`
  """
  @spec migration_completed() :: atom()
  def migration_completed(), do: :migration_completed_hook

  @doc """
  Hook triggered when children are forwarded to other nodes during migration
  or when stop requests are redirected to the actual node hosting the child.

  Data: `%{forwards: [{node(), [map()]}]}`
  """
  @spec children_forwarded() :: atom()
  def children_forwarded(), do: :children_forwarded_hook

  @doc """
  Hook triggered before processes are redistributed.

  Data: `%{event: :node_join | :node_leave, nodes: [node()]}`
  """
  @spec pre_redistribution() :: atom()
  def pre_redistribution(), do: :pre_redistribution_hook

  @doc """
  Hook triggered after processes are redistributed.

  Data: `%{event: :node_join | :node_leave, nodes: [node()]}`
  """
  @spec post_redistribution() :: atom()
  def post_redistribution(), do: :post_redistribution_hook

  @doc """
  Hook triggered before the children of a process are started.

  Data: `%{request: request, hub: hub}`

  Consumed by: `:dg_pre_start_handler` (Guided distribution strategy)
  """
  @spec pre_children_start() :: atom()
  def pre_children_start(), do: :pre_children_start_hook

  @doc """
  Hook triggered right after the children of a process are started.

  Data: `%{children: [%{child_id: cid, pid: pid, result: result, nodes: [node()], child_spec: spec, metadata: map()}]}`

  Consumed by: `:rr_post_start` (Replication strategy), `:mhs_process_startups` (HotSwap), `:mcs_process_startups` (ColdSwap)
  """
  @spec post_children_start() :: atom()
  def post_children_start(), do: :post_children_start_hook

  @doc """
  Hook triggered before redistribution of children is called.

  This is only called with node addition or removal from the cluster.

  Data: `%{children: list(), event: :node_leave, node: node()}`

  Consumed by: `:rr_post_update` (Replication strategy)
  """
  @spec pre_children_redistribution() :: atom()
  def pre_children_redistribution(), do: :pre_children_redistribution_hook

  @doc """
  Hook triggered inside the coordinator `terminate/2` function.

  Data: `%{reason: any()}`

  Consumed by: `:ch_shutdown` (ConsistentHashing), `:mhs_shutdown` (HotSwap), `:mcs_shutdown` (ColdSwap)
  """
  @spec coordinator_shutdown() :: atom()
  def coordinator_shutdown(), do: :coordinator_shutdown_hook

  @doc """
  Hook triggered right after process has been restarted by local supervisor
  and the pid has been updated.

  Data: `%{node: node(), pid: pid()}`
  """
  @spec child_pid_updated() :: atom()
  def child_pid_updated(), do: :child_pid_updated_hook

  @doc """
  Hook triggered right before the supervisor starts the child process.

  This is an alter hook used to modify child process data before it is started.

  Data: `map()` (the child data map, returned modified)
  """
  @spec child_data_alter() :: atom()
  def child_data_alter(), do: :child_data_alter_hook

  @doc """
  Hook dispatched when handover states have been delivered to migrated processes.

  Data: `%{child_ids: [child_id()], target_node: node()}`
  """
  @spec handover_delivered() :: atom()
  def handover_delivered(), do: :handover_delivered_hook

  @doc """
  Hook dispatched when children are added to the deferred-migration list
  because they deferred (or did not answer) a migration consent query.

  Data: `%{child_ids: [child_id()]}`
  """
  @spec migration_deferred() :: atom()
  def migration_deferred(), do: :migration_deferred_hook

  @doc """
  Hook dispatched when a node drain completes, including deadline-forced
  completion.

  Data: `%{migrated: non_neg_integer(), forced: non_neg_integer()}`
  """
  @spec drain_completed() :: atom()
  def drain_completed(), do: :drain_completed_hook

  @doc """
  Hook dispatched when the centralized load balancer scoreboard is updated.

  Data: `%{scoreboard: term(), node: node()}`
  """
  @spec scoreboard_updated() :: atom()
  def scoreboard_updated(), do: :scoreboard_updated_hook

  @doc """
  Hook dispatched on every coordinator `:recovery_state` transition when the hub
  has opted into `:auto_recovery`. The only transition is
  `:recovering → :normal` (`reason: :reconcile_complete`), fired when the first
  orphan reconcile round completes.

  Part of the **experimental** boot-recovery feature; may change in future releases.

  Data: `%{hub_id: atom(), from: atom(), to: atom(), reason: atom(), measurements: map()}`
  where `measurements` carries the first round's counts (`candidates`, `orphans`,
  `started`, `duplicates`, `elapsed_ms`).
  """
  @spec recovery_state_changed() :: atom()
  def recovery_state_changed(), do: :recovery_state_changed_hook

  @doc """
  Hook dispatched once per coordinator lifetime, before the **first** orphan
  reconcile round issues any start. Part of the **experimental** boot-recovery
  feature; may change in future releases. This hook is dispatched **synchronously** —
  the coordinator awaits each registered handler's reply before proceeding,
  so handlers may block on prerequisite-service readiness.

  Handlers should return quickly; the per-handler budget is bounded by
  `:reconcile_interval_ms`. Crashes inside handlers are caught and logged; the
  round proceeds regardless. Subsequent rounds do not re-fire it — per-round
  observability is `reconcile_round/0`.

  Data: `%{hub_id: atom(), child_count: non_neg_integer()}` where `child_count` is
  the durable candidate count for the round.
  """
  @spec pre_recovery_replay() :: atom()
  def pre_recovery_replay(), do: :pre_recovery_replay_hook

  @doc """
  Hook dispatched once per coordinator lifetime, after the first orphan reconcile
  round completes (whether or not it started anything). Async.

  Part of the **experimental** boot-recovery feature; may change in future releases.

  Data: `%{hub_id: atom(), child_count: non_neg_integer(), succeeded: non_neg_integer(), failed: non_neg_integer(), reason: atom()}`
  """
  @spec post_recovery_replay() :: atom()
  def post_recovery_replay(), do: :post_recovery_replay_hook

  @doc """
  Hook dispatched at the end of **every** orphan reconcile round, including rounds
  that find nothing — a silent reconcile stays distinguishable from a stalled one.

  Part of the **experimental** boot-recovery feature; may change in future releases.

  Data: `%{hub_id: atom(), first_round: boolean(), measurements: map()}` where
  `measurements` is `%{candidates, orphans, started, skipped_pending, duplicates,
  elapsed_ms}`.
  """
  @spec reconcile_round() :: atom()
  def reconcile_round(), do: :reconcile_round_hook

  @doc """
  Hook dispatched by the node that stops its own instance of a child observed
  running on more than one node. The instance on the child's ring owner is kept;
  when no observed instance is on the owner, the lexicographically lowest node
  name is kept.

  Part of the **experimental** boot-recovery feature; may change in future releases.

  Data: `%{hub_id: atom(), child_id: term(), instance_count: pos_integer(), kept_node: node(), stopped_nodes: [node()]}`
  """
  @spec reconcile_duplicate() :: atom()
  def reconcile_duplicate(), do: :reconcile_duplicate_hook
end
