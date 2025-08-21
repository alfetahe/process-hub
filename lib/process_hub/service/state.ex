defmodule ProcessHub.Service.State do
  @moduledoc """
  The state service provides API functions for managing the state of the hub and
  locking/unlocking the local event handler.
  """

  alias :blockade, as: Blockade
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.PriorityLevel
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Hub

  @doc "Returns a boolean indicating whether the hub is locked."
  @spec is_locked?(Hub.t()) :: boolean
  def is_locked?(hub) do
    {:ok, prio_level} = Blockade.get_priority(hub.procs.event_queue)

    prio_level === PriorityLevel.locked()
  end

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
  Locks the event handler and dispatches the priority state updated hook.
  """
  @spec lock_event_handler(Hub.t(), boolean() | nil) :: :ok
  def lock_event_handler(hub, deadlock_recover \\ true) do
    options = lock_options(hub.storage.misc, deadlock_recover)

    Blockade.set_priority(
      hub.procs.event_queue,
      PriorityLevel.locked(),
      options
    )

    dispatch_lock(hub.storage.hook, options)

    :ok
  end

  @doc """
  Unlocks the event handler and dispatches the priority state updated hook.
  """
  @spec unlock_event_handler(Hub.t()) :: :ok
  def unlock_event_handler(hub) do
    Blockade.set_priority(
      hub.procs.event_queue,
      PriorityLevel.unlocked(),
      %{local_priority_set: true}
    )

    dispatch_unlock(hub.storage.hook, %{})

    :ok
  end

  @doc """
  Locks the event handler and kills the local distributed supervisor.
  """
  @spec toggle_quorum_failure(Hub.t()) :: :ok | {:error, :already_partitioned}
  def toggle_quorum_failure(hub) do
    unless is_partitioned?(hub) do
      lock_event_handler(hub, false)
      Supervisor.terminate_child(hub.procs.initializer, :dist_sup)

      :ok
    else
      {:error, :already_partitioned}
    end
  end

  @doc """
  Unlocks the local event handler and restarts the local distributed supervisor.
  """
  @spec toggle_quorum_success(Hub.t()) :: :ok | {:error, :not_partitioned}
  def toggle_quorum_success(hub) do
    if is_partitioned?(hub) do
      Supervisor.restart_child(
        hub.procs.initializer,
        :dist_sup
      )

      unlock_event_handler(hub)

      :ok
    else
      {:error, :not_partitioned}
    end
  end

  defp dispatch_lock(hook_storage, options) do
    HookManager.dispatch_hook(
      hook_storage,
      Hook.priority_state_updated(),
      {PriorityLevel.locked(), options}
    )
  end

  defp dispatch_unlock(hook_storage, options) do
    HookManager.dispatch_hook(
      hook_storage,
      Hook.priority_state_updated(),
      {PriorityLevel.unlocked(), options}
    )
  end

  defp lock_options(misc_storage, deadlock_recover) do
    case deadlock_recover do
      false -> %{}
      true -> %{reset_after: Storage.get(misc_storage, StorageKey.dlrt())}
    end
    |> Map.put(:local_priority_set, true)
  end
end
