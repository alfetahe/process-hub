# Required for Elixir < 1.13
ExUnit.start()

defmodule Test.Helper.Common do
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Utility.Name
  alias ProcessHub.Service.Ring
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy

  use ExUnit.Case, async: false

  def even_sum_sequence(start, total) do
    Enum.reduce(start..total, 2, fn num, acc ->
      2 * num + acc
    end)
  end

  def stop_peers(peer_nodes, count) do
    stopped_peers = Enum.take(peer_nodes, count)

    Enum.each(stopped_peers, fn {_name, pid} ->
      :peer.stop(pid)
    end)

    Bag.receive_multiple(count, :nodedown, error_msg: "Nodedown timeout")

    stopped_peers
  end

  def validate_started_children(%{hub_id: hub_id} = _context, child_specs) do
    compare_started_children(child_specs, hub_id)
  end

  def validate_singularity(%{hub_id: hub_id} = _context) do
    registry = ProcessHub.process_registry(hub_id)

    Enum.each(registry, fn {child_id, {_, nodes}} ->
      ring = Ring.get_ring(hub_id)
      ring_nodes = Ring.key_to_nodes(ring, child_id, 1)

      assert length(nodes) === 1, "The child #{child_id} is not started on single node"

      assert Enum.at(nodes, 0) |> elem(0) === Enum.at(ring_nodes, 0),
             "The child #{child_id} node does not match ring node"
    end)
  end

  def validate_replication(%{hub_id: hub_id, hub: hub, replication_factor: _rf} = _context) do
    registry = ProcessHub.process_registry(hub_id)
    replication_factor = RedundancyStrategy.replication_factor(hub.redundancy_strategy)

    Enum.each(registry, fn {child_id, {_, nodes}} ->
      ring = Ring.get_ring(hub_id)
      ring_nodes = Ring.key_to_nodes(ring, child_id, replication_factor)

      assert length(nodes) === replication_factor,
             "The child #{child_id} is started on #{length(nodes)} nodes but #{replication_factor} is expected."

      assert length(ring_nodes) === replication_factor,
             "The length of ring nodes does not match replication factor"

      assert Enum.all?(Keyword.keys(nodes), &Enum.member?(ring_nodes, &1)),
             "The child #{child_id} nodes do not match ring nodes"

      assert Enum.all?(ring_nodes, &Enum.member?(Keyword.keys(nodes), &1)),
             "The ring nodes do not match child #{child_id} nodes"
    end)
  end

  def validate_registry_length(%{hub_id: hub_id} = _context, child_specs) do
    registry = ProcessHub.process_registry(hub_id) |> Map.to_list()

    child_spec_len = length(child_specs)
    registry_len = length(registry)

    assert registry_len === child_spec_len,
           "The length of registry(#{registry_len}) does not match length of child specs(#{child_spec_len})"
  end

  def validate_redundancy_mode(
        %{hub_id: hub_id, replication_model: rep_model, hub: hub} = _context
      ) do
    registry = ProcessHub.process_registry(hub_id)
    dist_strat = hub.distribution_strategy
    redun_strat = hub.redundancy_strategy
    repl_fact = RedundancyStrategy.replication_factor(hub.redundancy_strategy)

    Enum.each(registry, fn {child_id, {_, nodes}} ->
      child_nodes =
        ProcessHub.Strategy.Distribution.Base.belongs_to(
          dist_strat,
          hub_id,
          child_id,
          repl_fact
        )

      master_node = RedundancyStrategy.master_node(redun_strat, hub_id, child_id, child_nodes)

      assert length(nodes) === repl_fact,
             "The length of nodes does not match replication factor"

      assert length(child_nodes) === repl_fact,
             "The length of belongs_to call does not match replication factor"

      for {node, pid} <- nodes do
        state = GenServer.call(pid, :get_state)

        cond do
          rep_model === :active_active ->
            assert state[:redun_mode] === :active,
                   "Exptected cid #{child_id} on node #{node} active recived #{state[:redun_mode]}"

          rep_model === :active_passive ->
            case state[:redun_mode] do
              :active ->
                assert master_node === node,
                       "Exptected cid #{child_id} on node #{node} to match #{master_node}"

              :passive ->
                assert master_node !== node,
                       "Exptected cid #{child_id} on node #{node} to not match #{master_node}"
            end
        end
      end
    end)
  end

  @spec sync_base_test(%{:hub_id => any(), optional(any()) => any()}, any(), :add | :rem, any()) ::
          :ok
  def sync_base_test(%{hub_id: hub_id} = _context, child_specs, type, opts \\ []) do
    case type do
      :add ->
        [{:start_children, Hook.registry_pid_inserted(), "Child add timeout.", child_specs}]

      :rem ->
        child_ids = Enum.map(child_specs, & &1.id)
        [{:stop_children, Hook.registry_pid_removed(), "Child remove timeout.", child_ids}]
    end
    |> sync_type_exec(hub_id, opts)
  end

  def sync_type_exec(actions, hub_id, opts) do
    Enum.each(actions, fn {function_name, hook_key, timeout_msg, children} ->
      apply(ProcessHub, function_name, [hub_id, children, Keyword.get(opts, :start_opts, [])])

      message_count =
        case Keyword.get(opts, :scope, :local) do
          :local -> length(children)
          :global -> length(children) * (length(Node.list()) + 1)
        end * Keyword.get(opts, :replication_factor, 1)

      Bag.receive_multiple(
        message_count,
        hook_key,
        error_msg: timeout_msg
      )
    end)
  end

  def validate_sync(%{hub_id: hub_id} = _context) do
    registry_data = ProcessHub.process_registry(hub_id)

    Enum.each(Node.list(), fn node ->
      remote_registry =
        :erpc.call(node, fn ->
          ProcessHub.process_registry(hub_id)
        end)

      Enum.each(registry_data, fn {id, {child_spec, nodes}} ->
        if remote_registry[id] do
          remote_child_spec = elem(remote_registry[id], 0)
          remote_nodes = elem(remote_registry[id], 1)

          assert remote_child_spec === child_spec, "Remote child spec does not match local one"

          Enum.each(nodes, fn node ->
            assert Enum.member?(remote_nodes, node),
                   "Remote registry does not include #{inspect(node)}"
          end)
        else
          assert false, "Remote registry does not have #{id} on node #{inspect(node)}"
        end
      end)
    end)
  end

  def compare_started_children(children, hub_id) do
    local_registry = ProcessHub.process_registry(hub_id) |> Map.new()

    Enum.each(children, fn child_spec ->
      {lchild_spec, _nodes} = Map.get(local_registry, child_spec.id, {nil, nil})

      assert lchild_spec === child_spec, "Child spec mismatch for #{child_spec.id}"
    end)
  end

  def trigger_periodc_sync(%{hub_id: hub_id, peer_nodes: nodes} = context, child_specs, :add) do
    SynchronizationStrategy.init_sync(
      context.hub.synchronization_strategy,
      hub_id,
      Keyword.keys(nodes)
    )

    Bag.receive_multiple(
      length(Node.list()) * length(child_specs),
      Hook.registry_pid_inserted(),
      error_msg: "Child add timeout."
    )
  end

  def trigger_periodc_sync(%{hub_id: hub_id, peer_nodes: nodes} = context, child_specs, :rem) do
    SynchronizationStrategy.init_sync(
      context.hub.synchronization_strategy,
      hub_id,
      Keyword.keys(nodes)
    )

    Bag.receive_multiple(
      length(Node.list()) * length(child_specs),
      Hook.registry_pid_removed(),
      error_msg: "Child remove timeout."
    )
  end

  def periodic_sync_base(%{hub_id: hub_id} = _context, child_specs, :rem) do
    Enum.each(child_specs, fn child_spec ->
      ProcessHub.DistributedSupervisor.terminate_child(
        Name.distributed_supervisor(hub_id),
        child_spec.id
      )

      ProcessHub.Service.ProcessRegistry.delete(hub_id, child_spec.id)
    end)

    Bag.receive_multiple(
      length(child_specs),
      Hook.registry_pid_removed(),
      error_msg: "Child remove timeout."
    )
  end

  def periodic_sync_base(%{hub_id: hub_id} = _context, child_specs, :add) do
    registry_data =
      Enum.map(child_specs, fn child_spec ->
        start_res =
          ProcessHub.DistributedSupervisor.start_child(
            Name.distributed_supervisor(hub_id),
            child_spec
          )

        case start_res do
          {:ok, pid} -> {child_spec.id, {child_spec, [{node(), pid}]}}
          unexpected -> {child_spec.id, unexpected}
        end
      end)
      |> Map.new()

    ProcessHub.Service.ProcessRegistry.bulk_insert(hub_id, registry_data)

    Bag.receive_multiple(
      length(child_specs),
      Hook.registry_pid_inserted(),
      error_msg: "Child add timeout."
    )
  end

  def sync_start(hub_id, child_specs) do
    ProcessHub.start_children(hub_id, child_specs, async_wait: true)
    |> ProcessHub.await()
  end
end
