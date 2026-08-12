defmodule ProcessHub.Initializer do
  @moduledoc """
  The main `ProcessHub` initializer supervisor module.

  This module is responsible for starting all the child processes of `ProcessHub`.
  """

  alias :blockade, as: Blockade
  alias ProcessHub.Service.Recovery
  alias ProcessHub.Service.LoggerService

  use Supervisor

  @doc "Starts a `ProcessHub` instance with all its children."
  @spec start_link(ProcessHub.t()) :: {:ok, pid()} | {:error, term()}
  def start_link(%ProcessHub{} = hub_settings) do
    case validate_config(hub_settings) do
      :ok ->
        warn_on_suboptimal_config(hub_settings)
        Supervisor.start_link(__MODULE__, hub_settings)

      {:error, _} = err ->
        err
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

  # Surfaced, never rejected: each of these still starts, just wastes work or
  # narrows a window the design relies on.
  defp warn_on_suboptimal_config(%ProcessHub{} = hub) do
    warn_on_debounce(hub)
    warn_on_reconcile_grace(hub)
  end

  # Bounded max-wait still flushes, but a debounce >= discover interval makes
  # every discovery tick wasted work.
  defp warn_on_debounce(%ProcessHub{
         hub_id: hub_id,
         cluster_event_debounce: debounce,
         hubs_discover_interval: discover
       })
       when is_integer(debounce) and is_integer(discover) and debounce >= discover do
    LoggerService.warning(
      ":cluster_event_debounce (@debounce ms) >= :hubs_discover_interval (@discover ms) " <>
        "for hub @hub_id; set :cluster_event_debounce below :hubs_discover_interval.",
      %{
        "hub_id" => inspect(hub_id),
        "debounce" => Integer.to_string(debounce),
        "discover" => Integer.to_string(discover)
      },
      prefix: "Initializer"
    )
  end

  defp warn_on_debounce(_), do: :ok

  # The first reconcile round computes a difference against whatever the cluster
  # has synced by then. A grace window no longer than a sync interval can fire
  # before the first exchange, so a returning node may still be holding a stale
  # `:running` row for a child the cluster has since stopped — and restart it.
  defp warn_on_reconcile_grace(%ProcessHub{
         hub_id: hub_id,
         auto_recovery: auto_recovery,
         synchronization_strategy: %{sync_interval: sync_interval}
       })
       when auto_recovery !== false and is_integer(sync_interval) do
    case Recovery.parse_config(auto_recovery) do
      {:ok, %{enabled?: true, reconcile_grace_ms: grace}} when grace <= sync_interval ->
        LoggerService.warning(
          ":auto_recovery reconcile_grace_ms (@grace ms) <= sync_interval (@sync ms) " <>
            "for hub @hub_id; the first reconcile round can run before the first " <>
            "synchronisation exchange. Set reconcile_grace_ms above sync_interval.",
          %{
            "hub_id" => inspect(hub_id),
            "grace" => Integer.to_string(grace),
            "sync" => Integer.to_string(sync_interval)
          },
          prefix: "Initializer"
        )

      _ ->
        :ok
    end
  end

  defp warn_on_reconcile_grace(_), do: :ok

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
    recovery_config = Recovery.config_or_disabled(hub_conf)
    storage = setup_storage(hub_id, hub_conf, recovery_config)
    procs = setup_procs(hub_id)

    children =
      [
        {Registry, keys: :unique, name: procs.system_registry},
        {ProcessHub.Service.ProcessRegistry, {hub_id, procs.process_registry, recovery_config}},
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

  # An opted-in hub never populates the live registry from disk: durable rows reach
  # the cluster through the orphan reconcile round, which starts only the
  # difference against what the cluster is observed to hold. Loading them here
  # would republish a returning node's stale view as fact.
  defp setup_storage(hub_id, hub_conf, recovery_config) do
    {backend_module, backend_opts} = resolve_registry_backend(hub_conf.registry_backend)

    backend_opts =
      if recovery_config.enabled?,
        do: Keyword.put(backend_opts, :recovery_replay, false),
        else: backend_opts

    {:ok, backend_ref} = backend_module.open(hub_id, backend_opts)
    ProcessHub.Service.Storage.register_backend(hub_id, backend_module, backend_ref)

    %{
      hook: :ets.new(hub_id, [:set, :public]),
      misc: :ets.new(hub_id, [:set, :public]),
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
