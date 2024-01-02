defmodule ProcessHub.Service.State do
  @moduledoc """
  The state service provides API functions for managing the state of the hub and
  locking/unlocking the local event handler.
  """

  alias :blockade, as: Blockade
  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Utility.Name
  alias ProcessHub.Constant.PriorityLevel
  alias ProcessHub.Constant.Hook

  @prio_reset 60000

  @doc "Returns a boolean indicating whether the hub is locked."
  @spec is_locked?(ProcessHub.hub_id()) :: boolean
  def is_locked?(hub_id) do
    {:ok, prio_level} = Blockade.get_priority(Name.local_event_queue(hub_id))

    prio_level === PriorityLevel.locked()
  end

  @doc "Returns a boolean indicating whether the hub cluster is partitioned."
  @spec is_partitioned?(atom) :: boolean
  def is_partitioned?(hub_id) do
    Process.whereis(Name.distributed_supervisor(hub_id)) === nil
  end

  @doc """
  Locks the local event handler and dispatches the priority state updated hook.
  """
  @spec lock_local_event_handler(ProcessHub.hub_id(), pos_integer() | nil) :: :ok
  def lock_local_event_handler(hub_id, reset \\ @prio_reset) do
    options =
      case reset do
        nil -> %{}
        _ -> %{reset_after: @prio_reset}
      end

    Name.local_event_queue(hub_id)
    |> Blockade.set_priority(PriorityLevel.locked(), options)

    HookManager.dispatch_hook(
      hub_id,
      Hook.priority_state_updated(),
      {PriorityLevel.locked(), options}
    )

    :ok
  end

  @doc """
  Unlocks the local event handler and dispatches the priority state updated hook.
  """
  @spec unlock_local_event_handler(ProcessHub.hub_id()) :: :ok
  def unlock_local_event_handler(hub_id) do
    local_event_queue = Name.local_event_queue(hub_id)

    Blockade.set_priority(local_event_queue, PriorityLevel.unlocked())

    HookManager.dispatch_hook(
      hub_id,
      Hook.priority_state_updated(),
      {PriorityLevel.unlocked(), {}}
    )

    :ok
  end

  @doc """
  Locks the local event handler and kills the local distributed supervisor.
  """
  @spec toggle_quorum_failure(ProcessHub.hub_id()) :: :ok | {:error, :already_partitioned}
  def toggle_quorum_failure(hub_id) do
    unless is_partitioned?(hub_id) do
      lock_local_event_handler(hub_id, nil)
      initializer = Name.initializer(hub_id)

      Supervisor.terminate_child(initializer, DistributedSupervisor)

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
      |> Supervisor.restart_child(DistributedSupervisor)

      unlock_local_event_handler(hub_id)

      :ok
    else
      {:error, :not_partitioned}
    end
  end
end
