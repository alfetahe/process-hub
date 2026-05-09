defmodule ProcessHub.Initializer do
  @moduledoc """
  The main `ProcessHub` initializer supervisor module.

  This module is responsible for starting all the child processes of `ProcessHub`.
  """

  alias :blockade, as: Blockade

  use Supervisor

  @doc "Starts a `ProcessHub` instance with all its children."
  @spec start_link(ProcessHub.t()) :: {:ok, pid()} | {:error, term()}
  def start_link(%ProcessHub{} = hub_settings) do
    case validate_config(hub_settings) do
      :ok -> Supervisor.start_link(__MODULE__, hub_settings)
      {:error, _} = err -> err
    end
  end

  def start_link(_), do: {:error, :expected_hub_settings}

  @doc false
  @spec validate_config(ProcessHub.t()) :: :ok | {:error, {:invalid_config, atom()}}
  defp validate_config(%ProcessHub{} = hub) do
    with :ok <- validate_handover_replication(hub) do
      :ok
    end
  end

  defp validate_handover_replication(%ProcessHub{
         migration_strategy: migration_strat,
         redundancy_strategy: redun_strat
       }) do
    handover_enabled =
      case migration_strat do
        %ProcessHub.Strategy.Migration.ColdSwap{handover: true} -> true
        %ProcessHub.Strategy.Migration.HotSwap{handover: true} -> true
        _ -> false
      end

    replication_enabled =
      match?(%ProcessHub.Strategy.Redundancy.Replication{}, redun_strat)

    if handover_enabled and replication_enabled do
      {:error, {:invalid_config, :handover_with_replication_not_supported}}
    else
      :ok
    end
  end

  @doc "Starts a `ProcessHub` instance with all its children."
  @spec stop(atom()) :: :ok | {:error, :not_alive}
  def stop(hub_id) do
    if ProcessHub.is_alive?(hub_id) do
      hub = GenServer.call(hub_id, :get_state)
      Supervisor.stop(hub.procs.initializer)
    else
      {:error, :not_alive}
    end
  end

  @impl true
  def init(%ProcessHub{hub_id: hub_id} = hub_conf) do
    storage = setup_storage(hub_id, hub_conf)
    procs = setup_procs(hub_id)

    children =
      [
        {Registry, keys: :unique, name: procs.system_registry},
        {ProcessHub.Service.ProcessRegistry, {hub_id, procs.process_registry}},
        {Blockade, %{name: procs.event_queue, priority_sync: false}},
        dist_sup(hub_conf, procs),
        {Task.Supervisor, name: procs.task_sup},
        {ProcessHub.Coordinator, {hub_conf, procs, storage}},
        {ProcessHub.Worker.WorkerQueue, {hub_id, procs.worker_queue, storage.misc}},
        {ProcessHub.Worker.BootstrapWorker, {hub_id, procs.bootstrap_worker, storage.misc}},
        {ProcessHub.Worker.Janitor,
         {
           hub_id,
           procs.janitor,
           storage.misc,
           hub_conf.storage_purge_interval
         }}
      ]

    opts = [strategy: :one_for_one]

    Supervisor.init(children, opts)
  end

  defp dist_sup(%ProcessHub{} = hub, procs) do
    args = {
      hub.hub_id,
      procs.dist_sup,
      hub.dsup_max_restarts,
      hub.dsup_max_seconds
    }

    %{
      id: :dist_sup,
      start: {ProcessHub.DistributedSupervisor, :start_link, [args]},
      shutdown: hub.dsup_shutdown_timeout
    }
  end

  defp setup_storage(hub_id, hub_conf) do
    hook_registry = :ets.new(hub_id, [:set, :public])
    misc_storage = :ets.new(hub_id, [:set, :public])

    {backend_module, backend_opts} = resolve_registry_backend(hub_conf.registry_backend)
    {:ok, backend_ref} = backend_module.open(hub_id, backend_opts)
    ProcessHub.Service.Storage.register_backend(hub_id, backend_module, backend_ref)

    %{
      hook: hook_registry,
      misc: misc_storage,
      registry_backend: {backend_module, backend_ref}
    }
  end

  defp resolve_registry_backend(:ets), do: {ProcessHub.Service.Storage.Ets, []}
  defp resolve_registry_backend(nil), do: {ProcessHub.Service.Storage.Ets, []}
  defp resolve_registry_backend({:dets, opts}) when is_list(opts), do: {ProcessHub.Service.Storage.Dets, opts}
  defp resolve_registry_backend({:durable_ets, opts}) when is_list(opts), do: {ProcessHub.Service.Storage.DurableEts, opts}
  defp resolve_registry_backend({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp resolve_registry_backend(module) when is_atom(module), do: {module, []}

  defp setup_procs(hub_id) do
    system_registry = :"hub.#{hub_id}.system_registry"

    %{
      initializer: self(),
      system_registry: system_registry,
      event_queue: :"hub.#{hub_id}.event_queue",
      process_registry: {:via, Registry, {system_registry, "process_registry"}},
      dist_sup: {:via, Registry, {system_registry, "dist_sup"}},
      task_sup: {:via, Registry, {system_registry, "task_sup"}},
      worker_queue: {:via, Registry, {system_registry, "worker_queue"}},
      bootstrap_worker: {:via, Registry, {system_registry, "bootstrap_worker"}},
      janitor: {:via, Registry, {system_registry, "janitor"}}
    }
  end
end
