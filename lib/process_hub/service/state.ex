defmodule ProcessHub.Service.State do
  @moduledoc """
  The state service provides API functions for managing the state of the hub and
  locking/unlocking the local event handler.
  """

  alias :blockade, as: Blockade
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Storage
  alias ProcessHub.Utility.Name
  alias ProcessHub.Constant.PriorityLevel
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey

  @doc "Returns a boolean indicating whether the hub is locked."
  @spec is_locked?(ProcessHub.hub_id()) :: boolean
  def is_locked?(hub_id) do
    {:ok, prio_level} = Blockade.get_priority(Name.event_queue(hub_id))

    prio_level === PriorityLevel.locked()
  end

  @doc "Returns a boolean indicating whether the hub cluster is partitioned."
  @spec is_partitioned?(atom) :: boolean
  def is_partitioned?(hub_id) do
    Process.whereis(Name.distributed_supervisor(hub_id)) === nil
  end

  @doc """
  Locks the event handler and dispatches the priority state updated hook.
  """
  @spec lock_event_handler(ProcessHub.hub_id(), boolean() | nil) :: :ok
  def lock_event_handler(hub_id, deadlock_recover \\ true) do
    options = lock_options(hub_id, deadlock_recover)

    Blockade.set_priority(
      Name.event_queue(hub_id),
      PriorityLevel.locked(),
      options
    )

    dispatch_lock(hub_id, options)

    :ok
  end

  @doc """
  Unlocks the event handler and dispatches the priority state updated hook.
  """
  @spec unlock_event_handler(ProcessHub.hub_id()) :: :ok
  def unlock_event_handler(hub_id) do
    Blockade.set_priority(
      Name.event_queue(hub_id),
      PriorityLevel.unlocked(),
      %{local_priority_set: true}
    )

    dispatch_unlock(hub_id, %{})

    :ok
  end

  @doc """
  Locks the event handler and kills the local distributed supervisor.
  """
  @spec toggle_quorum_failure(ProcessHub.hub_id()) :: :ok | {:error, :already_partitioned}
  def toggle_quorum_failure(hub_id) do
    unless is_partitioned?(hub_id) do
      lock_event_handler(hub_id, false)
      initializer = Name.initializer(hub_id)

      Supervisor.terminate_child(initializer, :distributed_supervisor)

      :ok
    else
      {:error, :already_partitioned}
    end
  end

  @doc """
  Unlocks the local event handler and restarts the local distributed supervisor.
  """
  @spec toggle_quorum_success(ProcessHub.hub_id()) :: :ok | {:error, :not_partitioned}
  def toggle_quorum_success(hub_id) do
    if is_partitioned?(hub_id) do
      Name.initializer(hub_id)
      |> Supervisor.restart_child(:distributed_supervisor)

      unlock_event_handler(hub_id)

      :ok
    else
      {:error, :not_partitioned}
    end
  end

  defp dispatch_lock(hub_id, options) do
    HookManager.dispatch_hook(
      hub_id,
      Hook.priority_state_updated(),
      {PriorityLevel.locked(), options}
    )
  end

  defp dispatch_unlock(hub_id, options) do
    HookManager.dispatch_hook(
      hub_id,
      Hook.priority_state_updated(),
      {PriorityLevel.unlocked(), options}
    )
  end

  defp lock_options(hub_id, deadlock_recover) do
    case deadlock_recover do
      false -> %{}
      true -> %{reset_after: Storage.get(hub_id, StorageKey.dlrt())}
    end
    |> Map.put(:local_priority_set, true)
  end
end
