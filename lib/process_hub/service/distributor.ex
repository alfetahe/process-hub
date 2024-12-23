defmodule ProcessHub.Service.Distributor do
  @moduledoc """
  The distributor service provides API functions for distributing child processes.
  """

  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Utility.Name
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.Mailbox
  alias ProcessHub.Service.Cluster
  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Handler.ChildrenRem.StopHandle
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy

  @doc "Initiates process redistribution."
  @spec children_redist_init(
          ProcessHub.hub_id(),
          node(),
          [ProcessHub.child_spec()],
          keyword() | nil
        ) ::
          {:ok, :redistribution_initiated} | {:ok, :no_children_to_redistribute}
  def children_redist_init(hub_id, node, child_specs, opts \\ []) do
    # Migration expects the `:migration_add` true flag otherwise the
    # remote node wont release the lock.
    opts = Keyword.put(opts, :migration_add, true)

    redist_children =
      Enum.map(child_specs, fn child_spec ->
        init_data([node], hub_id, child_spec)
        |> Map.merge(Map.new(opts))
      end)

    case length(redist_children) > 0 do
      true ->
        Dispatcher.children_migrate(hub_id, [{node, redist_children}], opts)

        {:ok, :redistribution_initiated}

      false ->
        {:ok, :no_children_to_redistribute}
    end
  end

  @doc "Initiates processes startup."
  @spec init_children(ProcessHub.hub_id(), [ProcessHub.child_spec()], keyword()) ::
          {:ok, :start_initiated}
          | (-> {:ok, list})
          | {:error,
             :child_start_timeout
             | :no_children
             | {:already_started, [ProcessHub.child_id()]}
             | any()}
  def init_children(_hub_id, [], _opts), do: {:error, :no_children}

  def init_children(hub_id, child_specs, opts) do
    with {:ok, strategies} <- init_strategies(hub_id),
         :ok <- init_distribution(hub_id, child_specs, opts, strategies),
         :ok <- init_registry_check(hub_id, child_specs, opts),
         {:ok, children_nodes} <- init_attach_nodes(hub_id, child_specs, strategies),
         :ok <- init_mailbox_cleanup(children_nodes, opts),
         {:ok, composed_data} <- init_compose_data(hub_id, children_nodes, opts) do
      pre_start_children(composed_data, hub_id, opts)
    else
      err -> err
    end
  end

  @doc "Initiates processes shutdown."
  @spec stop_children(ProcessHub.hub_id(), [ProcessHub.child_id()], keyword()) ::
          (-> {:error, list} | {:ok, list}) | {:ok, :stop_initiated}
  def stop_children(hub_id, child_ids, opts) do
    local_storage = Name.local_storage(hub_id)
    redun_strat = Storage.get(local_storage, StorageKey.strred())
    dist_strat = Storage.get(local_storage, StorageKey.strdist())
    repl_fact = RedundancyStrategy.replication_factor(redun_strat)
    self = self()

    Enum.reduce(child_ids, [], fn child_id, acc ->
      child_nodes = DistributionStrategy.belongs_to(dist_strat, hub_id, child_id, repl_fact)
      child_data = %{nodes: child_nodes, child_id: child_id}

      child_data =
        case Keyword.get(opts, :async_wait, false) do
          true -> Map.put(child_data, :reply_to, [self])
          false -> child_data
        end

      append_items =
        Enum.map(child_nodes, fn child_node ->
          existing_children = acc[child_node] || []

          {child_node, [child_data | existing_children]}
        end)

      Keyword.merge(acc, append_items)
    end)
    |> pre_stop_children(hub_id, opts)
  end

  @doc """
  Terminates child processes locally and propagates all nodes in the cluster
  to remove the child processes from their registry.
  """
  @spec children_terminate(
          ProcessHub.hub_id(),
          [ProcessHub.child_id()],
          ProcessHub.Strategy.Synchronization.Base,
          nil | [{ProcessHub.child_id(), [pid()]}]
        ) :: [StopHandle.t()]
  def children_terminate(hub_id, child_ids, sync_strategy, reply_opts \\ []) do
    dist_sup = Name.distributed_supervisor(hub_id)

    shutdown_results =
      Enum.map(child_ids, fn child_id ->
        result = DistributedSupervisor.terminate_child(dist_sup, child_id)

        {^child_id, found_child_reply_opt} = List.keyfind(reply_opts, child_id, 0, {child_id, []})
        {child_id, {result, found_child_reply_opt}}
      end)

    SynchronizationStrategy.propagate(
      sync_strategy,
      hub_id,
      shutdown_results,
      node(),
      :rem,
      []
    )

    shutdown_results
  end

  @doc """
  Returns all child processes started by the local node.

  Works similar to `Supervisor.which_children/1` but returns a list of tuple
  where the first element is the node name and the second child processes started under the node.
  """
  @spec which_children_local(ProcessHub.hub_id(), keyword() | nil) ::
          {node(),
           [{any, :restarting | :undefined | pid, :supervisor | :worker, :dynamic | list}]}
  def which_children_local(hub_id, _opts) do
    {node(), Supervisor.which_children(Name.distributed_supervisor(hub_id))}
  end

  @doc """
  Return a list of all child processes started by all nodes in the cluster.
  """
  @spec which_children_global(ProcessHub.hub_id(), keyword()) :: list
  def which_children_global(hub_id, opts) do
    timeout = Keyword.get(opts, :timeout, 5000)

    Cluster.nodes(hub_id, [:include_local])
    |> :erpc.multicall(fn -> __MODULE__.which_children_local(hub_id, opts) end, timeout)
    |> Enum.map(fn {_status, result} -> result end)
  end

  defp pre_start_children(startup_children, hub_id, opts) do
    Dispatcher.children_start(hub_id, startup_children, opts)

    case Keyword.get(opts, :async_wait, false) do
      false ->
        {:ok, :start_initiated}

      true ->
        fn ->
          receiveable(startup_children) |> Mailbox.receive_start_resp(opts)
        end
    end
  end

  defp init_distribution(hub_id, child_specs, opts, %{distribution: strategy}) do
    DistributionStrategy.children_init(strategy, hub_id, child_specs, opts)
  end

  defp init_strategies(hub_id) do
    local_storage = Name.local_storage(hub_id)

    {:ok,
     %{
       distribution: Storage.get(local_storage, StorageKey.strdist()),
       redundancy: Storage.get(local_storage, StorageKey.strred())
     }}
  end

  defp pre_stop_children(stop_children, hub_id, opts) do
    Dispatcher.children_stop(hub_id, stop_children)

    case Keyword.get(opts, :async_wait, false) do
      false ->
        {:ok, :stop_initiated}

      true ->
        fn ->
          receiveable(stop_children)
          |> Mailbox.receive_stop_resp(opts)
        end
    end
  end

  defp receiveable(nodes_children) do
    Enum.reduce(nodes_children, [], fn {node, children}, acc ->
      node_receivable =
        Enum.map(children, fn child ->
          child.child_id
        end)

      Keyword.put(acc, node, node_receivable)
    end)
  end

  defp init_data(child_nodes, hub_id, child_spec) do
    %{
      hub_id: hub_id,
      nodes: child_nodes,
      child_id: child_spec.id,
      child_spec: child_spec
    }
  end

  defp init_compose_data(hub_id, children, opts) do
    async_await = Keyword.get(opts, :async_wait, false)
    self = self()

    {:ok,
     Enum.reduce(children, [], fn {child_spec, child_nodes}, acc ->
       child_data = init_data(child_nodes, hub_id, child_spec)

       child_data =
         case async_await do
           true -> Map.put(child_data, :reply_to, [self])
           false -> child_data
         end

       append_items =
         Enum.map(child_nodes, fn child_node ->
           existing_children = acc[child_node] || []

           {child_node, [child_data | existing_children]}
         end)

       Keyword.merge(acc, append_items)
     end)}
  end

  defp init_attach_nodes(hub_id, child_specs, %{distribution: dist, redundancy: redun}) do
    repl_fact = RedundancyStrategy.replication_factor(redun)

    {:ok,
     Enum.map(child_specs, fn child_spec ->
       {child_spec, DistributionStrategy.belongs_to(dist, hub_id, child_spec.id, repl_fact)}
     end)}
  end

  defp init_mailbox_cleanup(children, opts) do
    case Keyword.get(opts, :check_mailbox) do
      true ->
        Enum.each(children, fn {%{id: child_id}, nodes} ->
          Enum.each(nodes, fn node ->
            receive do
              {:child_start_resp, ^child_id, _, ^node} -> nil
            after
              0 -> nil
            end
          end)
        end)

      false ->
        nil
    end

    :ok
  end

  defp init_registry_check(hub_id, child_specs, opts) do
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
