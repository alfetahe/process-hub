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

  defmacro __using__(_) do
    quote do
      @event_cluster_join :cluster_join_event
      @event_cluster_leave :cluster_leave_event
      @event_cluster_leave_batch :cluster_leave_batch_event
      @event_node_registry_broadcast :node_registry_broadcast_event
      @event_requests_handle :requests_handle_event
    end
  end
end
