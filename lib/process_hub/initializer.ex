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
  def start_link(hub_settings) when is_struct(hub_settings) do
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
    managers = %{
      coordinator: Name.coordinator(hub_id),
      local_event_queue: Name.local_event_queue(hub_id),
      global_event_queue: Name.global_event_queue(hub_id),
      distributed_supervisor: Name.distributed_supervisor(hub_id),
      task_supervisor: Name.task_supervisor(hub_id)
    }

    children =
      storage(hub_id) ++
        [
          {Blockade, %{name: managers.local_event_queue}},
          {Blockade, %{name: managers.global_event_queue}},
          {ProcessHub.DistributedSupervisor, {hub_id, managers}},
          {Task.Supervisor, name: managers.task_supervisor},
          {ProcessHub.Coordinator, {hub_id, hub, managers}},
          {ProcessHub.WorkerQueue, Name.worker_queue(hub_id)}
        ]

    opts = [strategy: :one_for_one]

    case Node.alive?() do
      true -> Supervisor.init(children, opts)
      false -> {:error, :local_node_not_alive}
    end
  end

  defp storage(hub_id) do
    [
      %{id: :process_registry, start: {Cachex, :start_link, [[name: Name.registry(hub_id)]]}},
      %{id: :local_storage, start: {Cachex, :start_link, [[name: hub_id]]}}
    ]
  end
end
