defmodule ProcessHub.Constant.Hook do
  @moduledoc """
  Defines the list of hooks that can be used to extend the functionality of ProcessHub.
  """

  @doc """
  Hook triggered when a new node has joined the hub cluster and before handling
  the node join event.
  """
  @spec pre_cluster_join() :: atom()
  def pre_cluster_join(), do: :pre_cluster_join_hook

  @doc """
  Hook triggered when a new node has joined the hub cluster and after handling
  the node join event.
  """
  @spec post_cluster_join() :: atom()
  def post_cluster_join(), do: :post_cluster_join_hook

  @doc """
  Hook triggered when a node has left the hub cluster and before handling
  the node leave event.
  """
  @spec pre_cluster_leave() :: atom()
  def pre_cluster_leave(), do: :pre_cluster_leave_hook

  @doc """
  Hook triggered when a node has left the hub cluster and before handling
  the node leave event.
  """
  @spec post_cluster_leave() :: atom()
  def post_cluster_leave(), do: :post_cluster_leave_hook

  @doc """
  Hook triggered when a new process is registered in the ProcessHub registry.
  """
  @spec registry_pid_inserted() :: atom()
  def registry_pid_inserted(), do: :registry_pid_insert_hook

  @doc """
  Hook triggered when a process is unregistered from the ProcessHub registry.
  """
  @spec registry_pid_removed() :: atom()
  def registry_pid_removed(), do: :registry_pid_remove_hook

  @doc """
  Hook triggered when a process is migrated to another node.
  """
  @spec children_migrated() :: atom()
  def children_migrated(), do: :children_migrated_hook

  @doc """
  Hook triggered when a process is migrated to another node.
  """
  @spec forwarded_migration() :: atom()
  def forwarded_migration(), do: :forwarded_migration_hook

  @doc """
  Hook triggered when the priority level of the local event queue has been updated.
  """
  @spec priority_state_updated() :: atom()
  def priority_state_updated(), do: :priority_state_updated_hook

  @doc """
  Hook triggered before processes are redistributed.
  """
  @spec pre_nodes_redistribution() :: atom()
  def pre_nodes_redistribution(), do: :pre_nodes_redistribution_hook

  @doc """
  Hook triggered after processes are redistributed.
  """
  @spec post_nodes_redistribution() :: atom()
  def post_nodes_redistribution(), do: :post_nodes_redistribution_hook

  @doc """
  Hook triggered before the children of a process are started.
  """
  @spec pre_children_start() :: atom()
  def pre_children_start(), do: :pre_children_start_hook

  @doc """
  Hook triggered right after the children of a process are started.
  """
  @spec post_children_start() :: atom()
  def post_children_start(), do: :post_children_start_hook

  @doc """
  Hook triggered before redistribution of children is called.

  This is only called with node addition or removal from the cluster.
  """
  @spec pre_children_redistribution() :: atom()
  def pre_children_redistribution(), do: :pre_children_redistribution_hook

  @doc """
  Hook triggered inside the coordinator `terminate/2` function.
  """
  @spec coordinator_shutdown() :: atom()
  def coordinator_shutdown(), do: :coordinator_shutdown_hook

  @doc """
  Hook triggered right after processes are started.
  """
  @spec process_startups() :: atom()
  def process_startups(), do: :process_startups_hook

  @doc """
  Hook triggered right after process has been restarted by local supervisor
  and the pid has been updated.
  """
  @spec child_process_pid_update() :: atom()
  def child_process_pid_update(), do: :child_process_pid_update_hook

  @doc """
  Hook triggered right before the supervisor starts the child process.

  This is used to update the child process data before it is started.
  """
  @spec child_data_alter() :: atom()
  def child_data_alter(), do: :child_data_alter_hook

  # TODO: need to be general hooks.
  @doc """
  Hook triggered after ColdSwap migration has delivered state to a new process.
  """
  @spec coldswap_handover_delivered() :: atom()
  def coldswap_handover_delivered(), do: :coldswap_handover_delivered_hook

  @doc """
  Hook triggered after HotSwap migration has delivered state to a new process.
  """
  @spec hotswap_handover_delivered() :: atom()
  def hotswap_handover_delivered(), do: :hotswap_handover_delivered_hook
end
