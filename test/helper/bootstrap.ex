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
  @default_migr_retention 5000
  @default_handover_confirm false

  # Partition tolerance options
  @default_quorum_size_static 4
  @default_quorum_size_dynamic 90
  @default_quorum_threshold_time 30000
  @default_startup_quorum_confirm false

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

    start_hubs(hub, [node() | Node.list()], listed_hooks)

    on_exit(:kill_hubs, fn ->
      kill_hubs(peer_nodes, hub_id)
    end)

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
      hooks: []
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

  def start_hubs(hub, nodes, listed_hooks, new_nodes \\ false) do
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
          {:ok, pid} -> :erlang.unlink(pid)
          {:error, error} -> throw(error)
        end
      end)
    end)

    # Make sure all nodes are up and running the ProcessHub supervisor.
    nodes_count = length(Node.list())

    msg_count =
      case new_nodes do
        false -> nodes_count * length(nodes)
        true -> length(nodes)
      end

    if nodes_count > 1 do
      Bag.receive_multiple(
        msg_count,
        Hook.post_cluster_join(),
        error_msg: "Bootstrap timeout."
      )
    end
  end

  defp migr_strategy(context) do
    case context[:migr_strategy] do
      :hot ->
        %ProcessHub.Strategy.Migration.HotSwap{
          retention: context[:migr_retention] || @default_migr_retention,
          handover: context[:migr_handover] || @default_migr_handover,
          confirm_handover: context[:handover_confirmation] || @default_handover_confirm
        }

      :cold ->
        %ProcessHub.Strategy.Migration.ColdSwap{}

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
