defmodule ProcessHub.Initializer do
  @moduledoc """
  The main `ProcessHub` initializer supervisor module.

  This module is responsible for starting all the child processes of `ProcessHub`.
  """

  alias ProcessHub.Utility.Name
  alias :blockade, as: Blockade

  use Supervisor

  @doc "Starts a `ProcessHub` instance with all its children."
  @spec start_link(ProcessHub.t()) :: {:ok, pid()} | {:error, term()}
  def start_link(%ProcessHub{} = hub_settings) do
    Supervisor.start_link(__MODULE__, hub_settings, name: Name.initializer(hub_settings.hub_id))
  end

  def start_link(_), do: {:error, :expected_hub_settings}

  @doc "Starts a `ProcessHub` instance with all its children."
  @spec stop(atom()) :: :ok | {:error, :not_alive}
  def stop(hub_id) do
    if ProcessHub.is_alive?(hub_id) do
      Supervisor.stop(Name.initializer(hub_id))
    else
      {:error, :not_alive}
    end
  end

  @impl true
  def init(%ProcessHub{hub_id: hub_id} = hub) do
    setup_storage(hub_id)

    managers = %{
      coordinator: hub_id,
      event_queue: Name.event_queue(hub_id),
      distributed_supervisor: Name.distributed_supervisor(hub_id),
      task_supervisor: Name.task_supervisor(hub_id)
    }

    children =
      [
        {Registry, keys: :unique, name: Name.system_registry(hub_id)},
        {Blockade, %{name: managers.event_queue, priority_sync: false}},
        dist_sup(hub, managers),
        {Task.Supervisor, name: managers.task_supervisor},
        {ProcessHub.Coordinator, {hub_id, hub, managers}},
        {ProcessHub.WorkerQueue, hub_id},
        {ProcessHub.Janitor, {hub_id, hub.storage_purge_interval}}
      ]

    opts = [strategy: :one_for_one]

    Supervisor.init(children, opts)
  end

  defp dist_sup(%ProcessHub{} = hub, managers) do
    args = {
      hub.hub_id,
      managers.distributed_supervisor,
      hub.dsup_max_restarts,
      hub.dsup_max_seconds
    }

    %{
      id: :distributed_supervisor,
      start: {ProcessHub.DistributedSupervisor, :start_link, [args]},
      shutdown: hub.dsup_shutdown_timeout
    }
  end

  defp setup_storage(hub_id) do
    :ets.new(hub_id, [:set, :public, :named_table])
    :ets.new(Name.hook_registry(hub_id), [:set, :public, :named_table])
    :ets.new(Name.local_storage(hub_id), [:set, :public, :named_table])
  end
end
