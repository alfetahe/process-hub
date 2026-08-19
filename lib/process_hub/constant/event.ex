defmodule ProcessHub.Constant.Event do
  @moduledoc """
  Custom events defined as macros.
  """

  @typedoc """
  Event used when a node joins the ProcessHub cluster.
  """
  @type event_cluster_join() :: :cluster_join_event

  @typedoc """
  Periodic presence re-announce; processed as a join only when it reveals a
  node not already in the cluster.
  """
  @type event_cluster_heartbeat() :: :cluster_heartbeat_event

  @typedoc """
  Event used when a node leaves the ProcessHub cluster.
  """
  @type event_post_cluster_leave() :: :cluster_leave_event

  @typedoc """
  Event a coordinator dispatches when it restarts within `:net_ticktime`, so
  peers can purge bindings that point at its now-dead pids before re-syncing.
  """
  @type event_node_restarted() :: :node_restarted_event

  @typedoc """
  Event used when broadcasting local registry data to nodes that join the cluster.
  """
  @type event_node_registry_broadcast() :: :node_registry_broadcast_event

  @typedoc """
  Event used when handling node requests (batched).
  """
  @type event_requests_handle() :: :requests_handle_event

  @typedoc """
  Full declared-list push from the hub leader after a mutation; receivers adopt
  it when its version is higher than their local copy's.
  """
  @type event_declared_adopt() :: :declared_adopt_event

  @typedoc """
  Declared-list version announce sent after a synchronisation round; a receiver
  holding a lower version pulls the full list from the announcer.
  """
  @type event_declared_version() :: :declared_version_event

  defmacro __using__(_) do
    quote do
      @event_cluster_join :cluster_join_event
      @event_cluster_heartbeat :cluster_heartbeat_event
      @event_node_restarted :node_restarted_event
      @event_cluster_leave :cluster_leave_event
      @event_cluster_leave_batch :cluster_leave_batch_event
      @event_node_registry_broadcast :node_registry_broadcast_event
      @event_requests_handle :requests_handle_event
      @event_declared_adopt :declared_adopt_event
      @event_declared_version :declared_version_event
    end
  end
end
