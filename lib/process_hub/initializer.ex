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
    Supervisor.start_link(__MODULE__, hub_settings)
  end

  def start_link(_), do: {:error, :expected_hub_settings}

  @doc "Starts a `ProcessHub` instance with all its children."
  @spec stop(atom()) :: :ok | {:error, :not_alive}
  def stop(hub_id) do
    if ProcessHub.is_alive?(hub_id) do
      hub = GenServer.call(hub_id, :get_state)
      Supervisor.stop(hub.managers.initializer)
    else
      {:error, :not_alive}
    end
  end

  @impl true
  def init(%ProcessHub{hub_id: hub_id} = hub) do
    storage = setup_storage(hub_id)
    managers = setup_managers(hub_id)

    children =
      [
        {Registry, keys: :unique, name: managers.system_registry},
        {Blockade, %{name: managers.event_queue, priority_sync: false}},
        dist_sup(hub, managers),
        {Task.Supervisor, name: managers.task_supervisor},
        {ProcessHub.Coordinator, {hub, managers, storage}},
        {ProcessHub.WorkerQueue, {hub_id, managers.worker_queue, storage.misc}},
        {ProcessHub.Janitor, {hub_id, managers.janitor, hub.storage_purge_interval}}
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

    hook_registry = :ets.new(Name.hook_registry(hub_id), [:set, :public, :named_table])
    misc_storage = :ets.new(Name.misc_storage(hub_id), [:set, :public, :named_table])

    %{
      hook: hook_registry,
      misc: misc_storage
    }
  end

  defp setup_mangers(hub_id) do
    system_registry = :"hub.#{hub_id}.system_registry"

    %{
      initializer: self(),
      system_registry: system_registry,
      event_queue: :"hub.#{hub_id}.event_queue",
      distributed_supervisor: {:via, Registry, {system_registry, "dist_sup"}},
      task_supervisor: {:via, Registry, {system_registry, "task_sup"}},
      worker_queue: {:via, Registry, {system_registry, "worker_queue"}},
      janitor: {:via, Registry, {system_registry, "janitor"}}
    }
  end
end
