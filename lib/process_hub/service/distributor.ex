defmodule ProcessHub.Service.Distributor do
  @moduledoc """
  The distributor service provides API functions for distributing child processes.
  """

  alias ProcessHub.AsyncPromise
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.Mailbox
  alias ProcessHub.Service.Cluster
  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Handler.ChildrenRem.StopHandle
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Hub

  # 10 seconds
  @default_init_timeout 10000

  @doc "Initiates process redistribution."
  @spec children_redist_init(
          Hub.t(),
          node(),
          [{ProcessHub.child_spec(), ProcessHub.child_metadata()}],
          keyword() | nil
        ) ::
          {:ok, :redistribution_initiated} | {:ok, :no_children_to_redistribute}
  def children_redist_init(hub, node, children_data, opts \\ []) do
    # Migration expects the `:migration_add` true flag otherwise the
    # remote node wont release the lock.
    opts = Keyword.put(opts, :migration_add, true)

    redist_children =
      Enum.map(children_data, fn {child_spec, metadata} ->
        init_data([node], hub.hub_id, child_spec, metadata)
        |> Map.merge(Map.new(opts))
      end)

    case length(redist_children) > 0 do
      true ->
        Dispatcher.children_migrate(hub.managers.event_queue, [{node, redist_children}], opts)

        {:ok, :redistribution_initiated}

      false ->
        {:ok, :no_children_to_redistribute}
    end
  end

  # TODO: Replace with coordinator function.
  @doc "Get hub struct from coordinator for testing purposes."
  @spec get_hub_struct(ProcessHub.hub_id()) :: ProcessHub.Hub.t()
  def get_hub_struct(hub_id) do
    GenServer.call(hub_id, :get_state)
  end

  @doc "Initiates processes startup."
  @spec init_children(ProcessHub.Hub.t(), [ProcessHub.child_spec()], keyword()) ::
          {:ok, :start_initiated}
          | (-> {:ok, list})
          | {:error,
             :child_start_timeout
             | :no_children
             | {:already_started, [ProcessHub.child_id()]}
             | any()}
  def init_children(_hub, [], _opts), do: {:error, :no_children}

  def init_children(hub, child_specs, opts) do
    with {:ok, strategies} <- init_strategies(hub),
         :ok <- init_distribution(hub, child_specs, opts, strategies),
         :ok <- init_registry_check(hub, child_specs, opts),
         {:ok, children_nodes} <- init_attach_nodes(hub, child_specs, strategies),
         {:ok, composed_data} <- init_compose_data(hub, children_nodes, opts) do
      pre_start_children(hub, composed_data, opts)
    else
      err -> err
    end
  end

  @doc "Initiates processes shutdown."
  @spec stop_children(Hub.t(), [ProcessHub.child_id()], keyword()) ::
          (-> {:error, list} | {:ok, list}) | {:ok, :stop_initiated}
  def stop_children(hub, child_ids, opts) do
    redun_strat = Storage.get(hub.storage.misc, StorageKey.strred())
    dist_strat = Storage.get(hub.storage.misc, StorageKey.strdist())
    repl_fact = RedundancyStrategy.replication_factor(redun_strat)

    Enum.reduce(child_ids, [], fn child_id, acc ->
      child_nodes = DistributionStrategy.belongs_to(dist_strat, hub, child_id, repl_fact)
      child_data = %{nodes: child_nodes, child_id: child_id}

      append_items =
        Enum.map(child_nodes, fn child_node ->
          existing_children = acc[child_node] || []

          {child_node, [child_data | existing_children]}
        end)

      Keyword.merge(acc, append_items)
    end)
    |> pre_stop_children(hub, opts)
  end

  @doc """
  Terminates child processes locally and propagates all nodes in the cluster
  to remove the child processes from their registry.
  """
  @spec children_terminate(
          Hub.t(),
          [ProcessHub.child_id()],
          ProcessHub.Strategy.Synchronization.Base,
          keyword()
        ) :: [StopHandle.t()]
  def children_terminate(hub, child_ids, sync_strategy, stop_opts \\ []) do
    dist_sup = hub.managers.distributed_supervisor

    shutdown_results =
      Enum.map(child_ids, fn child_id ->
        result = DistributedSupervisor.terminate_child(dist_sup, child_id)

        {child_id, result, node()}
      end)

    SynchronizationStrategy.propagate(
      sync_strategy,
      hub,
      shutdown_results,
      node(),
      :rem,
      stop_opts
    )

    shutdown_results
  end

  @doc """
  Returns all child processes started by the local node.

  Works similar to `Supervisor.which_children/1` but returns a list of tuple
  where the first element is the node name and the second child processes started under the node.
  """
  @spec which_children_local(Hub.t(), keyword() | nil) ::
          {node(),
           [{any, :restarting | :undefined | pid, :supervisor | :worker, :dynamic | list}]}
  def which_children_local(hub, _opts) do
    {node(), Supervisor.which_children(hub.managers.distributed_supervisor)}
  end

  @doc """
  Return a list of all child processes started by all nodes in the cluster.
  """
  @spec which_children_global(Hub.t(), keyword()) :: list
  def which_children_global(hub, opts) do
    timeout = Keyword.get(opts, :timeout, 5000)

    Cluster.nodes(hub.storage.misc, [:include_local])
    |> :erpc.multicall(fn -> __MODULE__.which_children_local(hub, opts) end, timeout)
    |> Enum.map(fn {_status, result} -> result end)
  end

  # TODO: add tests and documentation.
  def default_init_opts(opts) do
    Keyword.put_new(opts, :timeout, @default_init_timeout)
    |> Keyword.put_new(:async_wait, false)
    |> Keyword.put_new(:check_existing, true)
    |> Keyword.put_new(:return_first, false)
    |> Keyword.put_new(:on_failure, :continue)
    |> Keyword.put_new(:metadata, %{})
    |> Keyword.put_new(:await_timeout, 60000)
  end

  defp pre_start_children(hub, startup_children, opts) do
    case Keyword.get(opts, :on_failure, :continue) do
      :continue ->
        case Keyword.get(opts, :async_wait, false) do
          true ->
            promise = async_wait_startup(hub, startup_children, opts)
            {:ok, promise}

          false ->
            Dispatcher.children_start(hub.hub_id, startup_children, opts)
            {:ok, :start_initiated}
        end

      :rollback ->
        spawn_failure_handler(hub, startup_children, opts)
    end
  end

  defp pre_stop_children(stop_children, hub, opts) do
    case Keyword.get(opts, :async_wait, false) do
      false ->
        Dispatcher.children_stop(hub.hub_id, stop_children, opts)
        {:ok, :stop_initiated}

      true ->
        {receiver_pid, _, await_promise} = spawn_collector(hub, :stop, opts)
        opts = Keyword.put(opts, :reply_to, [receiver_pid])
        Dispatcher.children_stop(hub.hub_id, stop_children, opts)
        {:ok, await_promise}
    end
  end

  defp async_wait_startup(hub, startup_children, opts) do
    {collect_from, required_cids} =
      Enum.reduce(startup_children, {[], []}, fn {node, children}, {cf, rc} ->
        {[node | cf], rc ++ Enum.map(children, &Map.get(&1, :child_id))}
      end)

    opts =
      opts
      |> Keyword.put(:collect_from, Enum.uniq(collect_from))
      |> Keyword.put(:required_cids, Enum.uniq(required_cids))

    {receiver_pid, _, await_promise} = spawn_collector(hub, :start, opts)

    Dispatcher.children_start(
      hub.hub_id,
      startup_children,
      Keyword.put(opts, :reply_to, [receiver_pid])
    )

    await_promise
  end

  defp spawn_failure_handler(hub, startup_children, opts) do
    ref = make_ref()

    collector_pid =
      spawn(fn ->
        Process.send_after(
          self(),
          {:process_hub, :auto_shutdown},
          Keyword.get(opts, :await_timeout, 60_000)
        )

        promise = async_wait_startup(hub, startup_children, opts)
        results = handle_failures(hub.hub_id, AsyncPromise.await(promise))

        case Keyword.get(opts, :async_wait, false) do
          true ->
            receive do
              {:process_hub, :auto_shutdown} ->
                nil

              {:process_hub, :collect_results, from, ^ref} ->
                send(from, {:process_hub, :async_results, ref, results})
            end

          false ->
            nil
        end
      end)

    await_promise = %ProcessHub.AsyncPromise{
      promise_resolver: collector_pid,
      timeout: Keyword.get(opts, :timeout),
      ref: ref
    }

    case Keyword.get(opts, :async_wait, false) do
      true ->
        {:ok, await_promise}

      false ->
        {:ok, :start_initiated}
    end
  end

  defp handle_failures(hub_id, startup_results) do
    case startup_results do
      {:ok, results} ->
        {:ok, results}

      {:error, {errs, success_results}} ->
        success_cids = Enum.map(success_results, fn {cid, _} -> cid end)

        # Stop the children that were started successfully.
        ProcessHub.stop_children(hub_id, success_cids, async_wait: true) |> ProcessHub.await()

        {:error, {errs, success_results}, :rollback}
    end
  end

  defp spawn_collector(hub, start_or_stop, opts) do
    ref = make_ref()

    pid =
      spawn(fn ->
        Process.send_after(
          self(),
          {:process_hub, :auto_shutdown},
          Keyword.get(opts, :await_timeout, 60_000)
        )

        results =
          case start_or_stop do
            :start -> Mailbox.collect_start_results(hub, opts)
            :stop -> Mailbox.collect_stop_results(hub, opts)
          end

        receive do
          {:process_hub, :auto_shutdown} ->
            nil

          {:process_hub, :collect_results, from, ^ref} ->
            send(from, {:process_hub, :async_results, ref, results})
        end
      end)

    await_promise = %ProcessHub.AsyncPromise{
      promise_resolver: pid,
      timeout: Keyword.get(opts, :timeout),
      ref: ref
    }

    {pid, ref, await_promise}
  end

  defp init_distribution(hub, child_specs, opts, %{distribution: strategy}) do
    DistributionStrategy.children_init(strategy, hub, child_specs, opts)
  end

  defp init_strategies(%Hub{storage: %{misc: misc_storage}}) do
    {:ok,
     %{
       distribution: Storage.get(misc_storage, StorageKey.strdist()),
       redundancy: Storage.get(misc_storage, StorageKey.strred())
     }}
  end

  defp init_data(child_nodes, hub_id, child_spec, metadata) do
    %{
      hub_id: hub_id,
      nodes: child_nodes,
      child_id: child_spec.id,
      child_spec: child_spec,
      metadata: metadata
    }
  end

  defp init_compose_data(%Hub{hub_id: hub_id}, children, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    {:ok,
     Enum.reduce(children, [], fn {child_spec, child_nodes}, acc ->
       child_data = init_data(child_nodes, hub_id, child_spec, metadata)

       append_items =
         Enum.map(child_nodes, fn child_node ->
           existing_children = acc[child_node] || []

           {child_node, [child_data | existing_children]}
         end)

       Keyword.merge(acc, append_items)
     end)}
  end

  defp init_attach_nodes(hub, child_specs, %{distribution: dist, redundancy: redun}) do
    repl_fact = RedundancyStrategy.replication_factor(redun)

    {:ok,
     Enum.map(child_specs, fn child_spec ->
       {child_spec, DistributionStrategy.belongs_to(dist, hub, child_spec.id, repl_fact)}
     end)}
  end

  defp init_registry_check(%Hub{hub_id: hub_id}, child_specs, opts) do
    case Keyword.get(opts, :check_existing) do
      true ->
        contains = ProcessRegistry.contains_children(hub_id, Enum.map(child_specs, & &1.id))

        case contains do
          [] -> :ok
          _ -> {:error, {:already_started, contains}}
        end

      false ->
        :ok
    end
  end
end
