defmodule ProcessHub.Strategy.Migration.Autonomous do
  @moduledoc """
  The autonomous migration strategy implements the `ProcessHub.Strategy.Migration.Base` protocol.

  Unlike ColdSwap and HotSwap which coordinate process migration between nodes via
  start/stop requests, the Autonomous strategy takes a fundamentally different approach:
  each node independently reconciles its local state against `belongs_to`, stopping
  children that shouldn't be here and starting children that should be here.

  There is no inter-node communication and no state handover.

  > #### Experimental {: .warning}
  >
  > This strategy is experimental and may change in future versions.
  """

  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Storage
  alias ProcessHub.Request.Handler.StartChildrenRequest

  @typedoc """
  The autonomous migration struct. No configuration options.
  """
  @type t() :: %__MODULE__{}

  defstruct []

  @doc false
  @spec reconcile(ProcessHub.Hub.t(), map(), %{ProcessHub.child_id() => [node()]}) :: map()
  def reconcile(hub, handler, cid_node_map) do
    local_node = node()
    registry_data = ProcessRegistry.dump(hub.hub_id)

    sync_strat =
      Map.get(handler, :sync_strat) || Storage.get(hub.storage.misc, StorageKey.strsyn())

    # Categorize children into to_stop and to_start.
    {to_stop, to_start} =
      Enum.reduce(cid_node_map, {[], []}, fn {child_id, all_calculated_nodes},
                                             {stop_acc, start_acc} ->
        primary_node = List.first(all_calculated_nodes)
        registry_entry = Map.get(registry_data, child_id)

        running_locally? =
          case registry_entry do
            {_cspec, node_pids, _meta} -> Keyword.has_key?(node_pids, local_node)
            _ -> false
          end

        # Stop: running locally but local node is NOT in any calculated position.
        stop_acc =
          if running_locally? and not Enum.member?(all_calculated_nodes, local_node) do
            [child_id | stop_acc]
          else
            stop_acc
          end

        # Start: primary is local node but NOT running locally.
        start_acc =
          if primary_node == local_node and not running_locally? do
            case registry_entry do
              {cspec, _node_pids, meta} -> [{cspec, meta} | start_acc]
              _ -> start_acc
            end
          else
            start_acc
          end

        {stop_acc, start_acc}
      end)

    # Stop children that shouldn't be here.
    if to_stop != [] do
      Distributor.children_terminate(hub, to_stop, sync_strat)
    end

    # Start children that should be here.
    if to_start != [] do
      requests = [StartChildrenRequest.for_contraction(hub, to_start)]
      Dispatcher.children_start(hub, requests)
    end

    handler
  end

  defimpl MigrationStrategy, for: ProcessHub.Strategy.Migration.Autonomous do
    alias ProcessHub.Strategy.Migration.Autonomous

    @impl true
    def init(strategy, _hub), do: strategy

    @impl MigrationStrategy
    def handle_topology_expansion(%Autonomous{}, hub, _nodes, handler) do
      # Compute distribution from ALL registry entries.
      registry_data = ProcessRegistry.dump(hub.hub_id)
      cids = Enum.map(registry_data, fn {cid, _} -> cid end)

      cid_node_map =
        if cids != [] do
          DistributionStrategy.belongs_to(
            handler.dist_strat,
            hub,
            cids,
            RedundancyStrategy.replication_factor(handler.redun_strat)
          )
        else
          %{}
        end

      # Populate calculated_cids for redundancy strategy downstream.
      handler = Map.put(handler, :calculated_cids, cid_node_map)

      Autonomous.reconcile(hub, handler, cid_node_map)
    end

    @impl MigrationStrategy
    def handle_topology_contraction(%Autonomous{}, hub, _removed_nodes, handler) do
      # Use pre-computed calculated_cids from NodeDown.distribute_processes.
      cid_node_map = Map.get(handler, :calculated_cids, %{})

      Autonomous.reconcile(hub, handler, cid_node_map)
    end
  end
end
