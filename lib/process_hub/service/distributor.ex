defmodule ProcessHub.Service.Distributor do
  @moduledoc """
  The distributor service provides API functions for distributing child processes.
  """

  alias ProcessHub.Service.LocalStorage
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Utility.Name
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.Mailbox
  alias ProcessHub.Service.Cluster
  alias ProcessHub.DistributedSupervisor
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy

  @doc "Initiates process redistribution."
  @spec child_redist_init(ProcessHub.hub_id(), ProcessHub.child_spec(), node(), keyword() | nil) ::
          {:ok, :redistribution_initiated}
  def child_redist_init(hub_id, child_spec, node, opts \\ []) do
    redist_child =
      init_data([node], hub_id, child_spec)
      |> Map.merge(Map.new(opts))

    Dispatcher.children_start(hub_id, [{node, [redist_child]}])

    {:ok, :redistribution_initiated}
  end

  @doc "Initiates processes startup."
  @spec init_children(ProcessHub.hub_id(), [ProcessHub.child_spec()], keyword()) ::
          {:ok, :start_initiated}
          | (-> {:ok, list})
          | {:error,
             :child_start_timeout | :no_children | {:already_started, [ProcessHub.child_id()]}}
  def init_children(_hub_id, [], _opts), do: {:error, :no_children}

  def init_children(hub_id, child_specs, opts) do
    with :ok <- init_registry_check(hub_id, child_specs, opts),
         {:ok, children_nodes} <- init_attach_nodes(hub_id, child_specs),
         :ok <- init_mailbox_cleanup(children_nodes, opts),
         {:ok, composed_data} <- init_compose_data(hub_id, children_nodes, opts) do
      pre_start_children(composed_data, hub_id, opts)
    else
      error -> error
    end
  end

  @doc "Initiates processes shutdown."
  @spec stop_children(ProcessHub.hub_id(), [ProcessHub.child_id()], keyword()) ::
          (-> {:error, list} | {:ok, list}) | {:ok, :stop_initiated}
  def stop_children(hub_id, child_ids, opts) do
    redun_strat = LocalStorage.get(hub_id, :redundancy_strategy)
    dist_strat = LocalStorage.get(hub_id, :distribution_strategy)
    repl_fact = RedundancyStrategy.replication_factor(redun_strat)

    Enum.reduce(child_ids, [], fn child_id, acc ->
      child_nodes = DistributionStrategy.belongs_to(dist_strat, hub_id, child_id, repl_fact)
      child_data = %{nodes: child_nodes, child_id: child_id}

      child_data =
        case Keyword.get(opts, :async_wait, false) do
          true -> Map.put(child_data, :reply_to, [self()])
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
  Terminates child process locally and propagates all nodes in the cluster
  to remove the child process from their registry.
  """
  @spec child_terminate(
          ProcessHub.hub_id(),
          ProcessHub.child_id(),
          ProcessHub.Strategy.Synchronization.Base
        ) :: :ok | {:error, :not_found | :restarting | :running}
  def child_terminate(hub_id, child_id, sync_strategy) do
    supervisor_resp =
      Name.distributed_supervisor(hub_id)
      |> DistributedSupervisor.terminate_child(child_id)

    SynchronizationStrategy.propagate(
      sync_strategy,
      hub_id,
      [{child_id, {supervisor_resp, []}}],
      node(),
      :rem
    )

    supervisor_resp
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
    Dispatcher.children_start(hub_id, startup_children)

    case Keyword.get(opts, :async_wait, false) do
      false ->
        {:ok, :start_initiated}

      true ->
        fn ->
          receiveable(startup_children)
          |> Mailbox.receive_start_resp(opts)
        end
    end
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

    {:ok,
     Enum.reduce(children, [], fn {child_spec, child_nodes}, acc ->
       child_data = init_data(child_nodes, hub_id, child_spec)

       child_data =
         case async_await do
           true -> Map.put(child_data, :reply_to, [self()])
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

  defp init_attach_nodes(hub_id, child_specs) do
    redun_strat = LocalStorage.get(hub_id, :redundancy_strategy)
    dist_strat = LocalStorage.get(hub_id, :distribution_strategy)
    repl_fact = RedundancyStrategy.replication_factor(redun_strat)

    {:ok,
     Enum.map(child_specs, fn child_spec ->
       {child_spec, DistributionStrategy.belongs_to(dist_strat, hub_id, child_spec.id, repl_fact)}
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
