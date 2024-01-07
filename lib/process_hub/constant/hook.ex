defmodule ProcessHub.Constant.Hook do
  @moduledoc """
  Defines the list of hooks that can be used to extend the functionality of ProcessHub.
  """

  @doc """
  Hook triggered when a new node is registered under the ProcessHub cluster.
  """
  @spec cluster_join() :: :cluster_join_hook
  def cluster_join(), do: :cluster_join_hook

  @doc """
  Hook triggered when a node is unregistered from the ProcessHub cluster.
  """
  @spec cluster_leave() :: :cluster_leave_hook
  def cluster_leave(), do: :cluster_leave_hook

  @doc """
  Hook triggered when a new process is registered in the ProcessHub registry.
  """
  @spec registry_pid_inserted() :: :registry_pid_insert_hook
  def registry_pid_inserted(), do: :registry_pid_insert_hook

  @doc """
  Hook triggered when a process is unregistered from the ProcessHub registry.
  """
  @spec registry_pid_removed() :: :registry_pid_remove_hook
  def registry_pid_removed(), do: :registry_pid_remove_hook

  @doc """
  Hook triggered when a process is migrated to another node.
  """
  @spec child_migrated() :: :child_migrated_hook
  def child_migrated(), do: :child_migrated_hook

  @doc """
  Hook triggered when a process is migrated to another node.
  """
  @spec forwarded_migration() :: :forwarded_migration_hook
  def forwarded_migration(), do: :forwarded_migration_hook

  @doc """
  Hook triggered when the priority level of the local event queue has been updated.
  """
  @spec priority_state_updated() :: :priority_state_updated_hook
  def priority_state_updated(), do: :priority_state_updated_hook

  @doc """
  Hook triggered before processes are redistributed.
  """
  @spec pre_nodes_redistribution() :: :pre_nodes_redistribution_hook
  def pre_nodes_redistribution(), do: :pre_nodes_redistribution_hook

  @doc """
  Hook triggered after processes are redistributed.
  """
  @spec post_nodes_redistribution() :: :post_nodes_redistribution_hook
  def post_nodes_redistribution(), do: :post_nodes_redistribution_hook

  # TODO: add tests and document the hooks.
  def pre_children_start(), do: :pre_children_start_hook
end
