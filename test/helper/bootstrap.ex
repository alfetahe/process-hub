# Required for Elixir < 1.13
ExUnit.start()

defmodule Test.Helper.Bootstrap do
  alias Test.Helper.TestNode
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Utility.Bag

  use ExUnit.Case, async: false

  # Synchronization options
  @default_sync_interval 600_000

  # Redundancy options
  @default_replication_factor 2
  @default_replication_model :active_passive
  @default_redundancy_signal :all

  # Migration options
  @default_migr_handover false

  # Partition tolerance options
  @default_quorum_size_static 4
  @default_quorum_size_dynamic 90
  @default_quorum_threshold_time 30000
  @default_startup_quorum_confirm false
  @default_initial_cluster_size 1
  @default_track_max_size true

  # Distrbution options
  @dist_stats_push_interval 30_000

  def init_nodes(nr_of_peers) do
    peer_nodes = TestNode.start_nodes(nr_of_peers)

    Enum.each(peer_nodes, fn {_, pid} ->
      :erlang.unlink(pid)
    end)

    on_exit(:kill_nodes, fn ->
      kill_peers(peer_nodes)
    end)

    %{
      peer_nodes: peer_nodes
    }
  end

  def bootstrap(%{hub_id: hub_id, listed_hooks: listed_hooks, peer_nodes: peer_nodes} = context) do
    # Flush messages
    Bag.all_messages()

    hub = gen_hub(context)

    # Check if hub will start partitioned (quorum_startup_confirm with insufficient nodes)
    # In this case, hooks won't fire so we skip await
    will_start_partitioned =
      context[:quorum_startup_confirm] == true and
        context[:partition_strategy] == :static and
        length(peer_nodes) + 1 < (context[:quorum_size] || @default_quorum_size_static)

    bootstrap_opts = if will_start_partitioned, do: [skip_await: true], else: []

    start_hubs(hub, [node() | Node.list()], listed_hooks, bootstrap_opts)

    on_exit(:kill_hubs, fn ->
      kill_hubs(peer_nodes, hub_id)
    end)

    # Flush messages.
    Bag.all_messages()

    context
    |> Map.put(:hub_conf, hub)
    |> Map.put(:hub, ProcessHub.Coordinator.get_hub(hub_id))
  end

  def gen_hub(context) do
    %ProcessHub{
      hub_id: context.hub_id,
      synchronization_strategy: sync_strategy(context),
      redundancy_strategy: redun_strategy(context),
      migration_strategy: migr_strategy(context),
      partition_tolerance_strategy: partition_strategy(context),
      distribution_strategy: distribution_strategy(context),
      hooks: [],
      # Disable debounce for tests
      cluster_event_debounce: 0
    }
  end

  def kill_peers(peer_nodes) do
    for {_peer, pid} <- peer_nodes do
      if Process.alive?(pid) do
        :peer.stop(pid)
      end
    end
  end

  defp kill_hubs(peer_nodes, hub_id) do
    for {node, _pid} <- peer_nodes do
      :erpc.call(node, fn ->
        ProcessHub.Initializer.stop(hub_id)
      end)
    end
  end

  def start_hubs(%ProcessHub{} = hub, nodes, listed_hooks, opts \\ []) do
    host_pid = self()
    local_node = node()

    Enum.each(nodes, fn node ->
      hooks =
        Enum.map(listed_hooks, fn {hook_key, scope} ->
          handler = {
            hook_key,
            [
              Bag.recv_hook(hook_key, host_pid)
            ]
          }

          case scope do
            :global ->
              handler

            :local ->
              if node !== local_node do
                nil
              else
                handler
              end
          end
        end)
        |> Enum.reject(fn hook -> hook === nil end)
        |> Map.new()

      :erpc.call(node, fn ->
        case ProcessHub.Initializer.start_link(%ProcessHub{hub | hooks: hooks}) do
          {:ok, pid} ->
            :erlang.unlink(pid)

          {:error, error} ->
            throw(error)
        end
      end)
    end)

    # Wait for cluster to stabilize after starting hubs.
    # Only await if post_cluster_join hook is registered
    has_join_hook =
      Enum.any?(listed_hooks, fn {hook, _s} ->
        hook == Hook.post_cluster_join()
      end)

    skip_await = Keyword.get(opts, :skip_await, false)

    if has_join_hook and not skip_await do
      # Determine scope based on whether post_cluster_join is in listed_hooks as :global
      scope =
        if Enum.any?(listed_hooks, fn {hook, s} ->
             hook == Hook.post_cluster_join() and s == :global
           end) do
          :global
        else
          :local
        end

      case Keyword.get(opts, :new_nodes, false) do
        true ->
          # New nodes joining an existing cluster
          # joining_count = length(nodes), cluster already has nodes_count + 1 (peers + local)
          nodes_count = length(Node.list())
          joining_count = length(nodes)

          if joining_count > 0 do
            cluster_size_before = nodes_count + 1

            Bag.await_cluster_join(
              joining_count,
              scope: scope,
              cluster_size: cluster_size_before,
              timeout: 15_000
            )
          end

        false ->
          # Initial bootstrap - all nodes forming the cluster together
          # Only the remote peers are "joining" the local node's cluster
          # Each peer joins and triggers a hook on all cluster members
          peer_count = length(Node.list())

          if peer_count > 0 do
            # For initial bootstrap with global hooks:
            # Each peer discovers the local node and vice versa
            # Total messages = peer_count * 2 (each peer fires, each local fires)
            # This is simplified: peer_count nodes joining cluster of size 1
            Bag.await_cluster_join(
              peer_count,
              scope: scope,
              cluster_size: 1,
              timeout: 15_000
            )
          end
      end
    end
  end

  defp migr_strategy(context) do
    case context[:migr_strategy] do
      :hot ->
        %ProcessHub.Strategy.Migration.HotSwap{
          handover: context[:migr_handover] || @default_migr_handover,
          state_ttl: context[:migr_state_ttl] || 30000,
          state_query_timeout: context[:migr_state_query_timeout] || 5000
        }

      :cold ->
        %ProcessHub.Strategy.Migration.ColdSwap{
          handover: context[:migr_handover] || @default_migr_handover,
          state_ttl: context[:migr_state_ttl] || 30000,
          state_query_timeout: context[:migr_state_query_timeout] || 5000
        }

      _ ->
        %ProcessHub.Strategy.Migration.ColdSwap{}
    end
  end

  defp sync_strategy(context) do
    sync_interval = context[:sync_interval] || @default_sync_interval

    case context[:sync_strategy] do
      :pubsub ->
        %ProcessHub.Strategy.Synchronization.PubSub{
          sync_interval: sync_interval
        }

      :gossip ->
        %ProcessHub.Strategy.Synchronization.Gossip{
          sync_interval: sync_interval,
          restricted_init: false
        }

      _ ->
        %ProcessHub.Strategy.Synchronization.PubSub{
          sync_interval: sync_interval
        }
    end
  end

  defp redun_strategy(context) do
    case context[:redun_strategy] do
      :replication ->
        %ProcessHub.Strategy.Redundancy.Replication{
          replication_factor: context[:replication_factor] || @default_replication_factor,
          replication_model: context[:replication_model] || @default_replication_model,
          redundancy_signal: context[:redundancy_signal] || @default_redundancy_signal
        }

      :singularity ->
        %ProcessHub.Strategy.Redundancy.Singularity{}

      _ ->
        %ProcessHub.Strategy.Redundancy.Singularity{}
    end
  end

  defp partition_strategy(context) do
    case context[:partition_strategy] do
      :static ->
        %ProcessHub.Strategy.PartitionTolerance.StaticQuorum{
          quorum_size: context[:quorum_size] || @default_quorum_size_static,
          startup_confirm: context[:quorum_startup_confirm] || @default_startup_quorum_confirm
        }

      :dynamic ->
        %ProcessHub.Strategy.PartitionTolerance.DynamicQuorum{
          quorum_size: context[:quorum_size] || @default_quorum_size_dynamic,
          threshold_time: context[:quorum_threshold_time] || @default_quorum_threshold_time
        }

      :majority ->
        %ProcessHub.Strategy.PartitionTolerance.MajorityQuorum{
          initial_cluster_size: context[:initial_cluster_size] || @default_initial_cluster_size,
          track_max_size: context[:track_max_size] || @default_track_max_size
        }

      :div ->
        %ProcessHub.Strategy.PartitionTolerance.Divergence{}

      _ ->
        %ProcessHub.Strategy.PartitionTolerance.Divergence{}
    end
  end

  defp distribution_strategy(context) do
    case context[:dist_strategy] do
      :guided ->
        %ProcessHub.Strategy.Distribution.Guided{}

      :consistent_hashing ->
        %ProcessHub.Strategy.Distribution.ConsistentHashing{}

      :centralized_load_balancer ->
        %ProcessHub.Strategy.Distribution.CentralizedLoadBalancer{
          push_interval: context[:dist_stats_push_interval] || @dist_stats_push_interval
        }

      _ ->
        %ProcessHub.Strategy.Distribution.ConsistentHashing{}
    end
  end
end
