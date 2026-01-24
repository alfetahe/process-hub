defmodule ProcessHub.Constant.Event do
  @moduledoc """
  Custom events defined as macros.
  """

  @typedoc """
  Event used when redistributing children to other nodes.
  """
  @type event_distribute_children() :: :distribute_children_event

  @typedoc """
  Event used when a node joins the ProcessHub cluster.
  """
  @type event_cluster_join() :: :cluster_join_event

  @typedoc """
  Event used when a node leaves the ProcessHub cluster.
  """
  @type event_post_cluster_leave() :: :cluster_leave_event

  @typedoc """
  Event used when a process has been registered in the ProcessHub registry.
  """
  @type event_children_registration() :: :children_registration_event

  @typedoc """
  Event used when external node sends migration event.
  """
  @type migration_add_event() :: :migration_add_event

  @typedoc """
  Child process is restarted by the local supervisor.
  """
  @type event_child_process_pid_update() :: :child_process_pid_update_event

  @typedoc """
  Event used when broadcasting local registry data to nodes that join the cluster.
  """
  @type event_node_join_sync() :: :node_join_sync_event

  @typedoc """
  Event used when handling node request.
  """
  @type event_request_handle() :: :request_handle_event

  defmacro __using__(_) do
    quote do
      @event_distribute_children :distribute_children_event
      @event_cluster_join :cluster_join_event
      @event_cluster_leave :cluster_leave_event
      @event_cluster_leave_batch :cluster_leave_batch_event
      # TODO: remove
      @event_children_registration :children_registration_event
      @event_child_process_pid_update :child_process_pid_update_event
      @event_node_join_sync :node_join_sync_event
      @event_request_handle :request_handle_event
    end
  end
end
