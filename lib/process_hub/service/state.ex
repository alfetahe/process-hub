defmodule ProcessHub.Service.State do
  @moduledoc """
  The state service provides API functions for managing the state of the hub.
  """

  alias ProcessHub.Hub

  @doc "Returns a boolean indicating whether the hub cluster is partitioned."
  @spec is_partitioned?(Hub.t()) :: boolean
  def is_partitioned?(hub) do
    case Registry.lookup(hub.procs.system_registry, "dist_sup") do
      [] -> true
      [{pid, _}] -> !Process.alive?(pid)
      _ -> false
    end
  end

  @doc """
  Terminates the local distributed supervisor.
  """
  @spec toggle_quorum_failure(Hub.t()) :: :ok | {:error, :already_partitioned}
  def toggle_quorum_failure(hub) do
    unless is_partitioned?(hub) do
      Supervisor.terminate_child(hub.procs.initializer, :dist_sup)

      :ok
    else
      {:error, :already_partitioned}
    end
  end

  @doc """
  Restarts the local distributed supervisor.
  """
  @spec toggle_quorum_success(Hub.t()) :: :ok | {:error, :not_partitioned}
  def toggle_quorum_success(hub) do
    if is_partitioned?(hub) do
      Supervisor.restart_child(
        hub.procs.initializer,
        :dist_sup
      )

      :ok
    else
      {:error, :not_partitioned}
    end
  end
end
