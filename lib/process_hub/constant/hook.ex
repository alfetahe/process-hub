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
  Hook dispatched when the centralized load balancer scoreboard is updated.

  Data: `%{scoreboard: term(), node: node()}`
  """
  @spec scoreboard_updated() :: atom()
  def scoreboard_updated(), do: :scoreboard_updated_hook

  @doc """
  Hook dispatched on every coordinator `:recovery_state` transition when the
  hub has opted into `:auto_recovery`.

  Data: `%{from: atom(), to: atom(), reason: atom(), peers: %{node() => atom()}}`
  """
  @spec recovery_state_changed() :: atom()
  def recovery_state_changed(), do: :recovery_state_changed_hook

  @doc """
  Hook dispatched once when the coordinator enters `:recovering`, before any
  `start_children` is dispatched. This hook is dispatched **synchronously** —
  the coordinator awaits each registered handler's reply before proceeding,
  so handlers may block on prerequisite-service readiness.

  Handlers should return quickly. Long blocks risk forcing the
  `:replay_timeout_ms` safety path. Crashes inside handlers are caught and
  logged; replay proceeds regardless.

  Data: `%{hub_id: atom(), child_count: non_neg_integer()}`
  """
  @spec pre_recovery_replay() :: atom()
  def pre_recovery_replay(), do: :pre_recovery_replay_hook

  @doc """
  Hook dispatched once when the coordinator leaves `:recovering` (whether via
  completion or via the `:replay_timeout_ms` safety path). Async.

  Data: `%{hub_id: atom(), child_count: non_neg_integer(), succeeded: non_neg_integer(), failed: non_neg_integer(), reason: atom()}`
  """
  @spec post_recovery_replay() :: atom()
  def post_recovery_replay(), do: :post_recovery_replay_hook
end
