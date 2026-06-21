defmodule ProcessHub.Strategy.Synchronization.Gossip do
  @moduledoc """
  The Gossip synchronization strategy provides a method for spreading information to other nodes
  within the `ProcessHub` cluster. It utilizes a gossip protocol to
  synchronize the process registry across the cluster.

  The Gossip strategy is most suitable for clusters are large. It scales well but produces
  higher latency than the PubSub strategy when operating in small clusters.
  When the cluster increases in size, Gossip protocol can also save bandwidth compared to PubSub.

  > The Gossip strategy works as follows:
  > - The synchronization process is initiated on a single node.
  > - The node collects its own local process registry data and appends it to the synchronization data.
  > - It selects a predefined number of nodes that have not yet added their local registry data.
  > - The node sends the data to the selected nodes.
  > - The nodes append their local registry data to the received data and send it to the next nodes.
  > - When all nodes have added their data to the synchronization data, the message will be sent to
  > nodes that have not yet acknowledged the synchronization ack.
  > - If node receives the synchronization data which contains all nodes data, it will
  > synchronize the data with it's local process registry and forward the data to the next nodes
  > that have not yet acknowledged the synchronization ack.
  > - When all nodes in the cluster have acknowledged the synchronization data, the synchronization
  > process is completed and the reference is invalidated.

  Each node also adds a timestamp to the synchronization data. This is used to ensure that
  the synchronization data is not older than the data that is already in the local process registry.
  """

  alias ProcessHub.Coordinator
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Synchronizer
  alias ProcessHub.Constant.Event
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Hub

  use Event

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

  @spec handle_propagation(
          ProcessHub.Strategy.Synchronization.Gossip.t(),
          Hub.t(),
          term()
        ) :: :ok
  def handle_propagation(strategy, hub, {ref, acks, requests}) do
    misc_storage = hub.storage.misc

    cached_acks =
      case Storage.get(misc_storage, ref) do
        nil -> []
        :invalidated -> :invalidated
        cached_acks -> cached_acks
      end

    case cached_acks do
      :invalidated ->
        nil

      _ ->
        acks = Enum.uniq(acks ++ cached_acks)
        unacked_nodes = unacked_nodes(acks, hub.storage.misc)

        if length(unacked_nodes) === 0 do
          invalidate_ref(strategy, misc_storage, ref)
        end

        acks =
          if Enum.member?(unacked_nodes, node()) do
            handle_request_propagation(hub.hub_id, requests)

            [node() | acks]
          else
            acks
          end

        Storage.insert(misc_storage, ref, acks, ttl: strategy.sync_interval)

        recipients_select(unacked_nodes, strategy)
        |> propagate_data(hub, strategy, {ref, acks, requests})
    end

    :ok
  end

  @spec invalidate_ref(
          ProcessHub.Strategy.Synchronization.Gossip.t(),
          :ets.tid(),
          reference()
        ) :: boolean()
  def invalidate_ref(strategy, misc_storage, ref) do
    Storage.insert(misc_storage, ref, :invalidated, ttl: strategy.sync_interval)
  end

  @spec propagate_data(
          [node()],
          Hub.t(),
          ProcessHub.Strategy.Synchronization.Gossip.t(),
          term()
        ) :: :ok
  def propagate_data(nodes, hub, strategy, data) do
    Enum.each(nodes, fn node ->
      Node.spawn(node, __MODULE__, :remote_propagate_cast, [hub.hub_id, strategy, data])
    end)
  end

  @doc false
  def remote_propagate_cast(hub_id, strategy, data) do
    local_hub = Coordinator.get_hub(hub_id)

    GenServer.cast(
      local_hub.procs.worker_queue,
      {:handle_work, fn -> __MODULE__.handle_propagation(strategy, local_hub, data) end}
    )
  end

  @spec recipients_select([node()], ProcessHub.Strategy.Synchronization.Gossip.t()) :: [node()]
  def recipients_select(nodes, strategy) do
    Enum.take_random(nodes, strategy.recipients)
  end

  @spec handle_request_propagation(
          ProcessHub.hub_id(),
          [struct()]
        ) :: :ok
  def handle_request_propagation(hub_id, requests) when is_list(requests) do
    try do
      send(hub_id, {@event_requests_handle, requests})
    catch
      _, _ -> :ok
    end
  end

  @spec unacked_nodes([node()], :ets.tid()) :: list()
  def unacked_nodes(sync_acks, misc_storage) do
    Cluster.nodes(misc_storage, [:include_local])
    |> Enum.filter(fn node -> !Enum.member?(sync_acks, node) end)
  end

  @doc false
  def remote_sync_cast(worker_queue, hub_id, strategy, sync_data, from_node) do
    GenServer.cast(
      worker_queue,
      {:handle_work,
       fn ->
         Synchronizer.exec_interval_sync(hub_id, strategy, sync_data, from_node)
       end}
    )
  end

  defimpl SynchronizationStrategy, for: ProcessHub.Strategy.Synchronization.Gossip do
    alias ProcessHub.Strategy.Synchronization.Gossip
    alias ProcessHub.Service.Cluster

    use Event

    @impl true
    def init(strategy, _hub), do: strategy

    @impl true
    @spec propagate(
            ProcessHub.Strategy.Synchronization.Gossip.t(),
            Hub.t(),
            [struct()],
            keyword()
          ) :: :ok
    def propagate(strategy, hub, requests, _opts) when is_list(requests) do
      ref = make_ref()
      Gossip.handle_request_propagation(hub.hub_id, requests)

      Cluster.nodes(hub.storage.misc)
      |> Gossip.recipients_select(strategy)
      |> Gossip.propagate_data(hub, strategy, {ref, [node()], requests})

      :ok
    end

    @impl true
    @spec init_sync(ProcessHub.Strategy.Synchronization.Gossip.t(), Hub.t(), [node()]) ::
            :ok
    def init_sync(strategy, hub, cluster_nodes) do
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
            hub,
            cluster_nodes,
            selected_node === Atom.to_string(local_node)
          )

        _ ->
          init_sync_internal(strategy, hub, cluster_nodes, true)
      end

      :ok
    end

    @impl true
    @spec handle_synchronization(
            ProcessHub.Strategy.Synchronization.Gossip.t(),
            Hub.t(),
            term(),
            node()
          ) :: :ok
    def handle_synchronization(
          strategy,
          hub,
          %{ref: ref, nodes_data: nodes_data, sync_acks: sync_acks},
          _remote_node
        ) do
      case merge_sync_data(hub.storage.misc, hub, ref, nodes_data, sync_acks) do
        :invalidated ->
          nil

        {sync_data, sync_acks} ->
          handle_sync_data(strategy, hub, ref, sync_data, sync_acks)
      end

      :ok
    end

    @impl true
    def broadcast_local_data(strategy, hub, local_data, target_nodes) do
      ref = make_ref()
      timestamp = Bag.timestamp(:microsecond)

      # Initialize with local node's data
      nodes_data = %{node() => {local_data, timestamp}}

      Storage.insert(hub.storage.misc, ref, {nodes_data, []}, ttl: strategy.sync_interval)

      # Start gossip to target nodes
      target_nodes
      |> Gossip.recipients_select(strategy)
      |> forward_join_data(strategy, hub, %{
        ref: ref,
        nodes_data: nodes_data,
        sync_acks: []
      })

      :ok
    end

    @impl true
    def handle_node_join_data(strategy, hub, sync_data, _remote_node) do
      %{ref: ref, nodes_data: nodes_data, sync_acks: sync_acks} = sync_data

      case merge_join_data(hub.storage.misc, hub, ref, nodes_data, sync_acks) do
        :invalidated ->
          :ok

        {merged_data, merged_acks} ->
          handle_join_sync_data(strategy, hub, ref, merged_data, merged_acks)
      end

      :ok
    end

    @spec handle_sync_data(
            ProcessHub.Strategy.Synchronization.Gossip.t(),
            Hub.t(),
            reference(),
            map(),
            list()
          ) :: :ok
    def handle_sync_data(
          strategy,
          %Hub{} = hub,
          ref,
          sync_data,
          sync_acks
        ) do
      Storage.insert(hub.storage.misc, ref, {sync_data, sync_acks}, ttl: strategy.sync_interval)

      missing_nodes = missing_nodes(sync_data, hub.storage.misc)

      cond do
        length(missing_nodes) === 0 ->
          unacked_nodes = Gossip.unacked_nodes(sync_acks, hub.storage.misc)

          sync_acks = sync_acks(hub, unacked_nodes, sync_acks, sync_data)

          if length(unacked_nodes) === 0 do
            Gossip.invalidate_ref(strategy, hub.storage.misc, ref)
          else
            forward_data(unacked_nodes, strategy, hub, %{
              ref: ref,
              nodes_data: sync_data,
              sync_acks: sync_acks
            })
          end

        length(missing_nodes) > 0 ->
          forward_data(missing_nodes, strategy, hub, %{
            ref: ref,
            nodes_data: sync_data,
            sync_acks: sync_acks
          })

        true ->
          throw("Invalid state")
      end
    end

    defp sync_acks(hub, unacked_nodes, sync_acks, sync_data) do
      if Enum.member?(unacked_nodes, node()) do
        sync_locally(hub.storage.misc, hub, sync_data)

        [node() | sync_acks]
      else
        sync_acks
      end
    end

    defp init_sync_internal(strategy, %Hub{} = hub, cluster_nodes, true) do
      ref = make_ref()

      sync_data = stamp_local_data(hub, %{}, Bag.timestamp(:microsecond))

      Storage.insert(hub.storage.misc, ref, {sync_data, []}, ttl: strategy.sync_interval)

      cluster_nodes
      |> Gossip.recipients_select(strategy)
      |> forward_data(strategy, hub, %{
        ref: ref,
        nodes_data: sync_data,
        sync_acks: []
      })
    end

    defp init_sync_internal(_strategy, _hub, _cluster_nodes, false) do
      :ok
    end

    # Stamp this node's own data into the gossip payload. A node that has hosted
    # no child this boot stamps the `:suppressed` marker instead of its empty
    # registry: it stays a key so gossip still converges (missing_nodes is
    # satisfied), but receivers skip it so it never makes peers delete its
    # records via detach_data (see Synchronizer.broadcastable_local_data/1).
    defp stamp_local_data(hub, nodes_data, timestamp) do
      data =
        case Synchronizer.broadcastable_local_data(hub) do
          {:ok, local_data} -> local_data
          :suppress -> :suppressed
        end

      Map.put(nodes_data, node(), {data, timestamp})
    end

    defp merge_sync_data(misc_storage, hub, ref, nodes_data, sync_acks) do
      local_timestamp = Bag.timestamp(:microsecond)
      nodes_data = stamp_local_data(hub, nodes_data, local_timestamp)

      case Storage.get(misc_storage, ref) do
        nil ->
          {nodes_data, []}

        :invalidated ->
          :invalidated

        {cached_data, cached_acks} ->
          merged_data =
            Map.merge(nodes_data, cached_data, fn _node_key, {ld, lt}, {rd, rt} ->
              cond do
                lt > rt -> {ld, lt}
                true -> {rd, rt}
              end
            end)

          {merged_data, Enum.uniq(cached_acks ++ sync_acks)}
      end
    end

    defp sync_locally(misc_storage, hub, nodes_data) do
      node_timestamps =
        case Storage.get(misc_storage, StorageKey.gct()) do
          nil -> %{}
          node_timestamps -> node_timestamps
        end

      Map.delete(nodes_data, node())
      |> Enum.each(fn {node, {data, timestamp}} ->
        # Make sure that we don't process data that is older than what we already have.
        node_timestamp = Map.get(node_timestamps, node, nil)

        cond do
          node_timestamp === nil ->
            sync_locally_node(misc_storage, hub, node, data, timestamp)

          node_timestamp < timestamp ->
            sync_locally_node(misc_storage, hub, node, data, timestamp)

          true ->
            :ok
        end
      end)
    end

    defp sync_locally_node(_misc_storage, _hub, _node, :suppressed, _timestamp), do: :ok

    defp sync_locally_node(misc_storage, hub, node, data, timestamp) do
      Synchronizer.append_data(hub, %{node => data})
      Synchronizer.detach_data(hub, %{node => data})

      update_node_timestamps(misc_storage, node, timestamp)
    end

    defp update_node_timestamps(misc_storage, node, timestamp) do
      node_timestamps =
        case Storage.get(misc_storage, StorageKey.gct()) do
          nil -> %{}
          node_timestamps -> node_timestamps || %{}
        end
        |> Map.put(node, timestamp)

      Storage.insert(misc_storage, StorageKey.gct(), node_timestamps)
    end

    defp missing_nodes(nodes_data, misc_storage) do
      node_keys = Map.keys(nodes_data)

      Cluster.nodes(misc_storage, [:include_local])
      |> Enum.filter(fn node -> !Enum.member?(node_keys, node) end)
    end

    defp forward_data(recipients, strategy, hub, sync_data) do
      local_node = node()

      Enum.each(recipients, fn recipient ->
        Node.spawn(
          recipient,
          ProcessHub.Strategy.Synchronization.Gossip,
          :remote_sync_cast,
          [hub.procs.worker_queue, hub.hub_id, strategy, sync_data, local_node]
        )
      end)
    end

    # Node join specific helper functions

    defp forward_join_data(recipients, _strategy, hub, sync_data) do
      local_node = node()

      Enum.each(recipients, fn recipient ->
        send({hub.hub_id, recipient}, {@event_node_registry_broadcast, {sync_data, local_node}})
      end)
    end

    defp merge_join_data(misc_storage, hub, ref, nodes_data, sync_acks) do
      local_timestamp = Bag.timestamp(:microsecond)
      nodes_data = stamp_local_data(hub, nodes_data, local_timestamp)

      case Storage.get(misc_storage, ref) do
        nil ->
          {nodes_data, []}

        :invalidated ->
          :invalidated

        {cached_data, cached_acks} ->
          merged_data =
            Map.merge(nodes_data, cached_data, fn _node_key, {ld, lt}, {rd, rt} ->
              cond do
                lt > rt -> {ld, lt}
                true -> {rd, rt}
              end
            end)

          {merged_data, Enum.uniq(cached_acks ++ sync_acks)}
      end
    end

    defp handle_join_sync_data(strategy, %Hub{} = hub, ref, sync_data, sync_acks) do
      Storage.insert(hub.storage.misc, ref, {sync_data, sync_acks}, ttl: strategy.sync_interval)

      missing_nodes = missing_nodes(sync_data, hub.storage.misc)

      cond do
        length(missing_nodes) === 0 ->
          unacked_nodes = Gossip.unacked_nodes(sync_acks, hub.storage.misc)

          sync_acks = sync_join_acks(hub, unacked_nodes, sync_acks, sync_data)

          if length(unacked_nodes) === 0 do
            Gossip.invalidate_ref(strategy, hub.storage.misc, ref)
          else
            forward_join_data(unacked_nodes, strategy, hub, %{
              ref: ref,
              nodes_data: sync_data,
              sync_acks: sync_acks
            })
          end

        length(missing_nodes) > 0 ->
          forward_join_data(missing_nodes, strategy, hub, %{
            ref: ref,
            nodes_data: sync_data,
            sync_acks: sync_acks
          })

        true ->
          throw("Invalid state")
      end
    end

    defp sync_join_acks(hub, unacked_nodes, sync_acks, sync_data) do
      if Enum.member?(unacked_nodes, node()) do
        sync_join_locally(hub.storage.misc, hub, sync_data)

        [node() | sync_acks]
      else
        sync_acks
      end
    end

    defp sync_join_locally(misc_storage, hub, nodes_data) do
      node_timestamps =
        case Storage.get(misc_storage, StorageKey.gct()) do
          nil -> %{}
          node_timestamps -> node_timestamps
        end

      Map.delete(nodes_data, node())
      |> Enum.each(fn {node, {data, timestamp}} ->
        # Make sure that we don't process data that is older than what we already have.
        node_timestamp = Map.get(node_timestamps, node, nil)

        cond do
          node_timestamp === nil ->
            sync_join_locally_node(misc_storage, hub, node, data, timestamp)

          node_timestamp < timestamp ->
            sync_join_locally_node(misc_storage, hub, node, data, timestamp)

          true ->
            :ok
        end
      end)
    end

    defp sync_join_locally_node(_misc_storage, _hub, _node, :suppressed, _timestamp), do: :ok

    defp sync_join_locally_node(misc_storage, hub, node, data, timestamp) do
      Synchronizer.append_data(hub, %{node => data})
      # Also detach stale entries that no longer exist on the remote node.
      # Without this, entries from previous connections (before disconnect/reconnect)
      # are never cleaned up, causing registry divergence to compound across cycles.
      Synchronizer.detach_data(hub, %{node => data})

      update_node_timestamps(misc_storage, node, timestamp)
    end
  end
end
