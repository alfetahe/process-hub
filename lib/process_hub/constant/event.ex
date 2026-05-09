defmodule ProcessHub.Constant.Event do
  @moduledoc """
  Custom events defined as macros.
  """

  @typedoc """
  Event used when a node joins the ProcessHub cluster.
  """
  @type event_cluster_join() :: :cluster_join_event

  @typedoc """
  Event used when a node leaves the ProcessHub cluster.
  """
  @type event_post_cluster_leave() :: :cluster_leave_event

  @typedoc """
  Event used when broadcasting local registry data to nodes that join the cluster.
  """
  @type event_node_registry_broadcast() :: :node_registry_broadcast_event

  @typedoc """
  Event used when handling node requests (batched).
  """
  @type event_requests_handle() :: :requests_handle_event

  @typedoc """
  Event a coordinator dispatches to announce its current `:recovery_state` to peers.
  """
  @type event_recovery_state_announce() :: :recovery_state_announce_event

  @typedoc """
  Event a coordinator dispatches to ask a peer for its current `:recovery_state`.
  """
  @type event_recovery_state_query() :: :recovery_state_query_event

  defmacro __using__(_) do
    quote do
      @event_cluster_join :cluster_join_event
      @event_cluster_leave :cluster_leave_event
      @event_cluster_leave_batch :cluster_leave_batch_event
      @event_node_registry_broadcast :node_registry_broadcast_event
      @event_requests_handle :requests_handle_event
      @event_recovery_state_announce :recovery_state_announce_event
      @event_recovery_state_query :recovery_state_query_event
    end
  end
end
