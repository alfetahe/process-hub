defmodule ProcessHub.Strategy.Synchronization.Gossip do
  @moduledoc """
  The Gossip synchronization strategy provides a method for spreading information to other nodes
  within the `ProcessHub` cluster. It utilizes a gossip protocol to
  synchronize the process registry across the cluster.

  The Gossip strategy is most suitable for clusters where the underlying network is
  not reliable, and messages can be lost. It has higher latency than the PubSub
  implementation but can be more reliable and save network bandwidth in some scenarios.

  > The Gossip strategy works as follows:
  > - The synchronization process is initiated on a single node.
  > - The node collects its own local process registry data and appends it to the synchronization data.
  > - It selects a predefined number of nodes that have not yet added their local registry data.
  > - The node sends the data to the selected nodes.
  > - The nodes append their local registry data to the received data and send it to the next nodes.
  > - When all nodes have added their data to the synchronization data, the message will be sent to
  > nodes that have not yet acknowledged the synchronization data.
  > - When all nodes in the cluster have acknowledged the synchronization data, the synchronization
  > process is completed.

  Each node also adds a timestamp to the synchronization data. This is used to ensure that
  the synchronization data is not older than the data that is already in the local process registry.
  """

  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Service.LocalStorage
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Synchronizer
  alias ProcessHub.Constant.Event
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Utility.Name

  @typedoc """
  The Gossip strategy configuration options.

  * `sync_interval` - The periodic synchronization interval in milliseconds. The default is `15000`.
  * `recipients` - The number of nodes that will receive the synchronization data and propagate it further. The default is `3`.
  * `restricted_init` - If set to `true`, the synchronization process will only be started on a single node.
    This node is selected by sorting the node names alphabetically and selecting the first node. The default is `true`.
  """
  @type t() :: %__MODULE__{
          sync_interval: pos_integer(),
          recipients: pos_integer(),
          restricted_init: boolean()
        }
  defstruct sync_interval: 15000, recipients: 3, restricted_init: true

  defimpl SynchronizationStrategy, for: ProcessHub.Strategy.Synchronization.Gossip do
    use Event

    @spec propagate(
            ProcessHub.Strategy.Synchronization.Gossip.t(),
            ProcessHub.hub_id(),
            [term()],
            node(),
            :add | :rem
          ) :: :ok
    def propagate(strategy, hub_id, children, update_node, type) do
      ref = make_ref()
      handle_propagation_local(strategy, hub_id, ref, children, update_node, type)

      Cluster.nodes(hub_id)
      |> recipients_select(strategy)
      |> propagate_data(strategy, hub_id, {ref, [node()], children, update_node}, type)

      :ok
    end

    @spec handle_propagation(
            ProcessHub.Strategy.Synchronization.Gossip.t(),
            ProcessHub.hub_id(),
            term(),
            :add | :rem
          ) :: :ok
    def handle_propagation(strategy, hub_id, {ref, acks, child_data, update_node}, type) do
      unless LocalStorage.exists?(hub_id, ref) do
        handle_propagation_local(strategy, hub_id, ref, child_data, update_node, type)

        Cluster.nodes(hub_id)
        |> Enum.filter(fn node -> !Enum.member?(acks, node) end)
        |> recipients_select(strategy)
        |> propagate_data(strategy, hub_id, {ref, [node() | acks], child_data, update_node}, type)
      end

      :ok
    end

    @spec init_sync(ProcessHub.Strategy.Synchronization.Gossip.t(), ProcessHub.hub_id(), [node()]) ::
            :ok
    def init_sync(strategy, hub_id, cluster_nodes) do
      case strategy.restricted_init do
        true ->
          local_node = node()

          selected_node =
            cluster_nodes
            |> Enum.map(&Atom.to_string(&1))
            |> Enum.sort()
            |> Enum.at(0)

          cluster_nodes = Enum.filter(cluster_nodes, fn node -> local_node !== node end)

          init_sync_internal(
            strategy,
            hub_id,
            cluster_nodes,
            selected_node === Atom.to_string(local_node)
          )

        _ ->
          init_sync_internal(strategy, hub_id, cluster_nodes, true)
      end

      :ok
    end

    @spec handle_synchronization(
            ProcessHub.Strategy.Synchronization.Gossip.t(),
            ProcessHub.hub_id(),
            term(),
            node()
          ) :: :ok
    def handle_synchronization(
          strategy,
          hub_id,
          %{ref: ref, nodes_data: nodes_data},
          _remote_node
        ) do
      case merge_sync_data(nodes_data, hub_id, ref) do
        :invalidated ->
          nil

        sync_data ->
          handle_sync_data(strategy, hub_id, ref, sync_data)
      end

      :ok
    end

    def handle_sync_data(strategy, hub_id, ref, sync_data) do
      sync_locally(hub_id, sync_data)
      LocalStorage.insert(hub_id, ref, sync_data, strategy.sync_interval)
      missing_nodes = missing_nodes(sync_data, hub_id)

      cond do
        length(missing_nodes) === 0 ->
          unacked_nodes = unacked_nodes(sync_data, hub_id)

          cond do
            length(unacked_nodes) === 0 ->
              invalidate_ref(strategy, hub_id, ref)
              :ok

            true ->
              forward_data(unacked_nodes, strategy, hub_id, %{ref: ref, nodes_data: sync_data})
          end

        length(missing_nodes) > 0 ->
          forward_data(missing_nodes, strategy, hub_id, %{ref: ref, nodes_data: sync_data})

        true ->
          throw("Invalid state")
      end
    end

    defp invalidate_ref(strategy, hub_id, ref) do
      LocalStorage.insert(hub_id, ref, :invalidated, strategy.sync_interval)
    end

    defp init_sync_internal(strategy, hub_id, cluster_nodes, true) do
      ref = make_ref()

      sync_data = %{
        node() => {Synchronizer.local_sync_data(hub_id), [node()], Bag.timestamp(:microsecond)}
      }

      LocalStorage.insert(hub_id, ref, sync_data, strategy.sync_interval)

      cluster_nodes
      |> recipients_select(strategy)
      |> forward_data(strategy, hub_id, %{ref: ref, nodes_data: sync_data})
    end

    defp init_sync_internal(_strategy, _hub_id, _cluster_nodes, false) do
      :ok
    end

    defp merge_sync_data(nodes_data, hub_id, ref) do
      local_timestamp = Bag.timestamp(:microsecond)
      local_data = Synchronizer.local_sync_data(hub_id)

      nodes_data =
        case Map.get(nodes_data, node(), nil) do
          nil ->
            Map.put(nodes_data, node(), {local_data, [node()], local_timestamp})

          {_, acks, _} ->
            Map.put(nodes_data, node(), {local_data, acks, local_timestamp})
        end
        |> Enum.map(fn {node, {data, acks, timestamp}} ->
          {node, {data, Enum.uniq([node() | acks]), timestamp}}
        end)
        |> Map.new()

      case LocalStorage.get(hub_id, ref) do
        nil ->
          nodes_data

        {_key, :invalidated, _tt} ->
          :invalidated

        {_key, cached_data, _ttl} ->
          Map.merge(nodes_data, cached_data, fn _node_key, {ld, la, lt}, {_rd, ra, rt} ->
            {ld, Enum.uniq(la ++ ra), max(lt, rt)}
          end)
      end
    end

    defp sync_locally(hub_id, nodes_data) do
      local_node = node()

      node_timestamps =
        case LocalStorage.get(hub_id, :gossip_node_timestamps) do
          nil -> %{}
          {_key, node_timestamps, _ttl} -> node_timestamps
        end

      Enum.each(nodes_data, fn {node, {data, acks, timestamp}} ->
        unless(node === local_node && !Enum.member?(acks, local_node)) do
          # Make sure that we don't process data that is older than what we already have.
          node_timestamp = Map.get(node_timestamps, node, nil)

          cond do
            node_timestamp === nil ->
              sync_locally_node(hub_id, node, data, timestamp)

            node_timestamp < timestamp ->
              sync_locally_node(hub_id, node, data, timestamp)

            true ->
              :ok
          end
        end
      end)
    end

    defp sync_locally_node(hub_id, node, data, timestamp) do
      Synchronizer.append_data(hub_id, %{node => data})
      Synchronizer.detach_data(hub_id, %{node => data})

      update_node_timestamps(hub_id, node, timestamp)
    end

    defp update_node_timestamps(hub_id, node, timestamp) do
      node_timestamps =
        case :ets.lookup(hub_id, :gossip_node_timestamps) do
          [] -> %{}
          [{_, node_timestamps, _}] -> node_timestamps || %{}
        end
        |> Map.put(node, timestamp)

      :ets.insert(hub_id, {:gossip_node_timestamps, node_timestamps, nil})
    end

    defp unacked_nodes(nodes_data, hub_id) do
      nodes = Cluster.nodes(hub_id, [:include_local])

      Enum.map(nodes_data, fn {_node, {_, acks, _}} ->
        Enum.filter(nodes, fn node -> !Enum.member?(acks, node) end)
      end)
      |> Enum.flat_map(fn nodes -> nodes end)
      |> Enum.uniq()
    end

    defp missing_nodes(nodes_data, hub_id) do
      node_keys = Map.keys(nodes_data)

      Cluster.nodes(hub_id, [:include_local])
      |> Enum.filter(fn node -> !Enum.member?(node_keys, node) end)
    end

    defp forward_data(recipients, strategy, hub_id, sync_data) do
      local_node = node()
      coordinator = Name.coordinator(hub_id)

      Enum.each(recipients, fn recipient ->
        Node.spawn(recipient, fn ->
          GenServer.cast(coordinator, {:handle_sync, strategy, sync_data, local_node})
        end)
      end)
    end

    defp handle_propagation_local(strategy, hub_id, ref, children, update_node, type) do
      LocalStorage.insert(hub_id, ref, nil, strategy.sync_interval)
      handle_propagation_type(hub_id, children, update_node, type)
    end

    defp handle_propagation_type(hub_id, children, updated_node, :add) do
      Name.coordinator(hub_id)
      |> send({@event_children_registration, {children, updated_node}})
    end

    defp handle_propagation_type(hub_id, children, updated_node, :rem) do
      Name.coordinator(hub_id)
      |> send({@event_children_unregistration, {children, updated_node}})
    end

    defp recipients_select(nodes, strategy) do
      Enum.take_random(nodes, strategy.recipients)
    end

    defp propagate_data(nodes, strategy, hub_id, data, type) do
      Enum.each(nodes, fn node ->
        Node.spawn(node, fn ->
          SynchronizationStrategy.handle_propagation(strategy, hub_id, data, type)
        end)
      end)
    end
  end
end