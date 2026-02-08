# Required for Elixir < 1.13
ExUnit.start()

defmodule Test.Helper.Common do
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Service.Ring
  alias ProcessHub.Constant.Hook
  alias Test.Helper.Bootstrap
  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy

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

  def validate_singularity(%{hub_id: hub_id, hub: hub} = _context) do
    registry = ProcessHub.registry_dump(hub_id)

    Enum.each(registry, fn {child_id, {_, nodes, _}} ->
      ring = Ring.get_ring(hub.storage.misc)
      ring_nodes = Ring.key_to_nodes(ring, child_id, 1)

      assert length(nodes) === 1, "The child #{child_id} is not started on single node"

      assert Enum.at(nodes, 0) |> elem(0) === Enum.at(ring_nodes, 0),
             "The child #{child_id} node does not match ring node"
    end)
  end

  def validate_replication(
        %{
          hub_id: hub_id,
          hub_conf: hub_conf,
          replication_factor: _rf,
          validate_metadata: vm,
          hub: hub
        } =
          _context
      ) do
    registry = ProcessHub.registry_dump(hub_id)
    replication_factor = RedundancyStrategy.replication_factor(hub_conf.redundancy_strategy)

    Enum.each(registry, fn {child_id, {_, nodes, metadata}} ->
      if vm do
        assert metadata === %{tag: hub_id |> Atom.to_string()}
      end

      ring = Ring.get_ring(hub.storage.misc)
      ring_nodes = Ring.key_to_nodes(ring, child_id, replication_factor)

      if length(nodes) !== replication_factor do
        # Debug: Check if PIDs are actually alive
        alive_status =
          Enum.map(nodes, fn {node_name, pid} ->
            is_alive =
              try do
                :erpc.call(node_name, Process, :alive?, [pid], 5000)
              catch
                _, _ -> {:error, :call_failed}
              end

            {node_name, pid, is_alive}
          end)

        IO.puts("\n=== DEBUG: Replication Mismatch ===")
        IO.puts("Child ID: #{child_id}")
        IO.puts("Expected RF: #{replication_factor}, Actual nodes: #{length(nodes)}")
        IO.puts("Ring nodes: #{inspect(ring_nodes)}")
        IO.puts("Registry nodes with alive status:")

        Enum.each(alive_status, fn {node_name, pid, is_alive} ->
          IO.puts("  #{node_name}: #{inspect(pid)} - alive: #{inspect(is_alive)}")
        end)

        IO.puts("=================================\n")

        flunk(
          "The child #{child_id} is started on #{length(nodes)} nodes but #{replication_factor} is expected."
        )
      end

      assert length(ring_nodes) === replication_factor,
             "The length of ring nodes does not match replication factor"

      registry_node_keys = Keyword.keys(nodes)

      assert Enum.all?(registry_node_keys, &Enum.member?(ring_nodes, &1)),
             "The child #{child_id} nodes do not match ring nodes"

      assert Enum.all?(ring_nodes, &Enum.member?(Keyword.keys(nodes), &1)),
             "The ring nodes do not match child #{child_id} nodes"
    end)
  end

  def validate_registry_length(%{hub_id: hub_id, hub: _hub} = context, child_specs) do
    registry = ProcessHub.registry_dump(hub_id) |> Map.to_list()

    child_spec_len = length(child_specs)
    registry_len = length(registry)

    assert registry_len === child_spec_len,
           "The length of registry(#{registry_len}) does not match length of child specs(#{child_spec_len})"
  end

  def validate_redundancy_mode(
        %{hub_id: hub_id, replication_model: rep_model, hub_conf: hub_conf, hub: hub} = _context
      ) do
    registry = ProcessHub.registry_dump(hub_id)
    dist_strat = hub_conf.distribution_strategy
    redun_strat = hub_conf.redundancy_strategy
    repl_fact = RedundancyStrategy.replication_factor(hub_conf.redundancy_strategy)
    child_ids = Map.keys(registry)
    children_nodes = DistributionStrategy.belongs_to(dist_strat, hub, child_ids, repl_fact)

    Enum.each(children_nodes, fn {child_id, child_nodes} ->
      master_node = RedundancyStrategy.master_node(redun_strat, hub, child_id, child_nodes)

      assert length(child_nodes) === repl_fact,
             "The length of belongs_to call does not match replication factor"

      registry_pid_nodes = Map.get(registry, child_id) |> elem(1)

      if is_list(registry_pid_nodes) do
        for {node, pid} <- registry_pid_nodes do
          state = GenServer.call(pid, :get_state)

          cond do
            rep_model === :active_active ->
              assert state[:redun_mode] === :active,
                     "Exptected cid #{child_id} on node #{node} active recived #{state[:redun_mode]}"

            rep_model === :active_passive ->
              # Ensure redun_mode is set to either :active or :passive
              assert state[:redun_mode] in [:active, :passive],
                     "Expected cid #{child_id} on node #{node} to have redun_mode :active or :passive, got #{inspect(state[:redun_mode])}"

              case state[:redun_mode] do
                :active ->
                  assert master_node === node,
                         "Expected cid #{child_id} on node #{node} (active) to match master node #{master_node}"

                :passive ->
                  assert master_node !== node,
                         "Expected cid #{child_id} on node #{node} (passive) to not match master node #{master_node}"
              end
          end
        end
      end
    end)
  end

  @spec sync_base_test(%{:hub_id => any(), optional(any()) => any()}, any(), :add | :rem, any()) ::
          :ok
  def sync_base_test(%{hub_id: hub_id} = context, child_specs, type, opts \\ []) do
    start_opts = Keyword.get(opts, :start_opts, [])

    start_opts =
      case Map.get(context, :validate_metadata, false) do
        true -> [{:metadata, %{tag: hub_id |> Atom.to_string()}} | start_opts]
        false -> start_opts
      end

    opts = Keyword.put(opts, :start_opts, start_opts)

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

  def validate_sync(%{hub_id: hub_id, validate_metadata: validate_metadata} = _context) do
    registry_data = ProcessHub.registry_dump(hub_id)

    Enum.each(Node.list(), fn node ->
      remote_registry =
        :erpc.call(node, fn ->
          ProcessHub.registry_dump(hub_id)
        end)

      Enum.each(registry_data, fn {id, {child_spec, nodes, metadata}} ->
        if validate_metadata do
          assert metadata === %{tag: hub_id |> Atom.to_string()}
        end

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
    local_registry = ProcessHub.registry_dump(hub_id) |> Map.new()

    Enum.each(children, fn child_spec ->
      {lchild_spec, _nodes, _metadata} = Map.get(local_registry, child_spec.id, {nil, nil, nil})

      assert lchild_spec === child_spec, "Child spec mismatch for #{child_spec.id}"
    end)
  end

  def trigger_periodc_sync(%{peer_nodes: nodes, hub: hub} = context, child_specs, :add) do
    SynchronizationStrategy.init_sync(
      context.hub_conf.synchronization_strategy,
      hub,
      Keyword.keys(nodes)
    )

    Bag.receive_multiple(
      length(Node.list()) * length(child_specs),
      Hook.registry_pid_inserted(),
      error_msg: "Child add timeout."
    )
  end

  def trigger_periodc_sync(%{peer_nodes: nodes, hub: hub} = context, child_specs, :rem) do
    SynchronizationStrategy.init_sync(
      context.hub_conf.synchronization_strategy,
      hub,
      Keyword.keys(nodes)
    )

    Bag.receive_multiple(
      length(Node.list()) * length(child_specs),
      Hook.registry_pid_removed(),
      error_msg: "Child remove timeout."
    )
  end

  def periodic_sync_base(%{hub_id: hub_id, hub: hub} = _context, child_specs, :rem) do
    Enum.each(child_specs, fn child_spec ->
      ProcessHub.DistributedSupervisor.terminate_child(
        hub.procs.dist_sup,
        child_spec.id
      )

      ProcessHub.Service.ProcessRegistry.delete(hub_id, child_spec.id,
        hook_storage: hub.storage.hook
      )
    end)

    Bag.receive_multiple(
      length(child_specs),
      Hook.registry_pid_removed(),
      error_msg: "Child remove timeout."
    )
  end

  def periodic_sync_base(%{hub_id: hub_id, hub: hub} = _context, child_specs, :add) do
    registry_data =
      Enum.map(child_specs, fn child_spec ->
        start_res =
          ProcessHub.DistributedSupervisor.start_child(
            hub.procs.dist_sup,
            child_spec
          )

        case start_res do
          {:ok, pid} -> {child_spec.id, {child_spec, [{node(), pid}], %{}}}
          unexpected -> {child_spec.id, unexpected}
        end
      end)
      |> Map.new()

    ProcessHub.Service.ProcessRegistry.bulk_insert(hub_id, registry_data,
      hook_storage: hub.storage.hook
    )

    Bag.receive_multiple(
      length(child_specs),
      Hook.registry_pid_inserted(),
      error_msg: "Child add timeout."
    )
  end

  def sync_start(hub_id, child_specs) do
    ProcessHub.start_children(hub_id, child_specs, awaitable: true)
    |> ProcessHub.Future.await()
  end

  @doc """
  Runs a migration test for both hot and cold swap strategies.

  Stops peer hubs, starts children on the local node, sets handoff data,
  restarts peer hubs, waits for migration to complete, then validates:
  - Handoff data was correctly transferred to migrated children
  - Each migrated child is running on the correct target node
  - Registry has the correct total child count
  - Each child is on the expected node(s) per the distribution strategy
  - Per-node child counts match the expected distribution
  """
  def run_migration_test(context, nodes_count, child_count) do
    %{hub_id: hub_id, listed_hooks: lh, hub_conf: hub_conf, hub: hub} = context

    child_specs =
      Bag.gen_child_specs(child_count, prefix: Atom.to_string(hub_id), id_type: :string)

    # Stop hubs on peer nodes before we start.
    Enum.each(Node.list(), fn node ->
      :erpc.call(node, ProcessHub.Initializer, :stop, [hub_id])
    end)

    # Node downs.
    Bag.receive_multiple(nodes_count, Hook.post_nodes_redistribution(),
      error_msg: "Post redistribution timeout"
    )

    # Confirm that hubs are stopped.
    Bag.receive_multiple(nodes_count, Hook.post_cluster_leave(),
      error_msg: "Cluster leave timeout"
    )

    # Start children on local node.
    sync_base_test(context, child_specs, :add)

    # Add custom data to children.
    Enum.each(child_specs, fn child_spec ->
      {_child_spec, [{_, pid}]} = ProcessHub.child_lookup(hub_id, child_spec.id)
      GenServer.call(pid, {:set_value, :handoff_data, child_spec.id})
    end)

    # Calculate expected distribution BEFORE restarting hubs.
    local_node = node()
    dist_strat = hub_conf.distribution_strategy
    child_ids = Enum.map(child_specs, & &1.id)
    expected_distribution = DistributionStrategy.belongs_to(dist_strat, hub, child_ids, 1)

    migrated_children =
      expected_distribution
      |> Enum.map(fn {child_id, nodes} -> {child_id, List.first(nodes)} end)
      |> Enum.filter(fn {_, n} -> n !== local_node end)

    # Restart hubs on peer nodes.
    Bootstrap.gen_hub(context)
    |> Bootstrap.start_hubs(Node.list(), lh, new_nodes: true, skip_await: true)

    # Wait for all handover deliveries to complete.
    migrated_child_ids = Enum.map(migrated_children, fn {child_id, _node} -> child_id end)

    if length(migrated_child_ids) > 0 do
      Bag.await_child_ids(
        Hook.handover_delivered(),
        migrated_child_ids,
        error_msg: "Handover delivery timeout",
        timeout: 60_000
      )
    end

    # Validate handoff data was transferred correctly.
    validate_handoff_data(hub_id, migrated_children)

    # Validate children are on the correct nodes.
    validate_node_placement(hub_id, migrated_children)

    # Validate full registry state and distribution.
    validate_migration_distribution(hub_id, child_specs, expected_distribution)
  end

  @doc """
  Validates that handoff data was correctly transferred to migrated children.
  """
  def validate_handoff_data(hub_id, migrated_children) do
    Enum.each(migrated_children, fn {child_id, _node} ->
      {_child_spec, nodes} = ProcessHub.child_lookup(hub_id, child_id)
      {_node, pid} = List.first(nodes)
      handover_data = GenServer.call(pid, {:get_value, :handoff_data})

      assert handover_data === child_id,
             "Child #{child_id} invalid handoff data: #{inspect(handover_data)} with pid #{inspect(pid)}"
    end)
  end

  @doc """
  Validates that each child in the list is running on the expected node.
  Accepts a list of `{child_id, expected_node}` tuples.
  """
  def validate_node_placement(hub_id, expected_children) do
    Enum.each(expected_children, fn {child_id, expected_node} ->
      {_child_spec, nodes} = ProcessHub.child_lookup(hub_id, child_id)
      {actual_node, _pid} = List.first(nodes)

      assert actual_node === expected_node,
             "Child #{child_id} is on #{actual_node}, expected #{expected_node}"
    end)
  end

  @doc """
  Validates the full registry state after migration:
  - Total child count matches expected
  - Each child is on the correct node(s) per the expected distribution
  - Per-node child counts match the expected distribution
  """
  def validate_migration_distribution(hub_id, child_specs, expected_distribution) do
    registry = ProcessHub.registry_dump(hub_id)

    # Validate total count.
    registry_count = map_size(registry)
    expected_count = length(child_specs)

    assert registry_count === expected_count,
           "Registry has #{registry_count} children, expected #{expected_count}"

    # Validate each child is on the expected node(s).
    Enum.each(expected_distribution, fn {child_id, expected_nodes} ->
      case Map.get(registry, child_id) do
        nil ->
          flunk("Child #{child_id} missing from registry after migration")

        {_spec, actual_node_pids, _metadata} ->
          actual_nodes = Keyword.keys(actual_node_pids) |> Enum.sort()
          sorted_expected = Enum.sort(expected_nodes)

          assert actual_nodes === sorted_expected,
                 "Child #{child_id} on nodes #{inspect(actual_nodes)}, expected #{inspect(sorted_expected)}"
      end
    end)

    # Validate per-node child counts.
    expected_per_node =
      expected_distribution
      |> Enum.flat_map(fn {_child_id, nodes} -> nodes end)
      |> Enum.frequencies()

    actual_per_node =
      registry
      |> Enum.flat_map(fn {_child_id, {_spec, node_pids, _meta}} ->
        Keyword.keys(node_pids)
      end)
      |> Enum.frequencies()

    Enum.each(expected_per_node, fn {n, expected_n_count} ->
      actual_n_count = Map.get(actual_per_node, n, 0)

      assert actual_n_count === expected_n_count,
             "Node #{n} has #{actual_n_count} children, expected #{expected_n_count}"
    end)
  end

  @doc """
  Waits until registry state is stable (all children have expected nodes based on ring).

  This function consumes registry hook events (insert/remove) while checking
  the registry state against expected node assignments from the hash ring.

  ## Parameters
  - `hub_id` - The hub identifier
  - `child_specs` - List of child specs to check
  - `rf` - Replication factor
  - `opts` - Options:
    - `:timeout` - Total timeout in ms (default: 10000ms)

  ## Returns
  `:ok` when registry is stable
  """
  @spec await_registry_stable(atom(), [map()], pos_integer(), Keyword.t()) :: :ok
  def await_registry_stable(hub_id, child_specs, rf, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    await_registry_stable_loop(hub_id, child_specs, rf, deadline)
  end

  defp await_registry_stable_loop(hub_id, child_specs, rf, deadline) do
    hub = ProcessHub.Coordinator.get_hub(hub_id)
    ring = Ring.get_ring(hub.storage.misc)
    current_registry = ProcessHub.registry_dump(hub_id)

    mismatches =
      Enum.filter(child_specs, fn child_spec ->
        child_id = child_spec.id

        current_nodes =
          case Map.get(current_registry, child_id) do
            {_, node_pids, _} -> Keyword.keys(node_pids) |> Enum.sort()
            nil -> []
          end

        expected_nodes = Ring.key_to_nodes(ring, child_id, rf) |> Enum.sort()

        current_nodes != expected_nodes
      end)

    if mismatches == [] do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        mismatch_ids = Enum.map(mismatches, & &1.id)

        raise "Registry stabilization timeout. Mismatched children: #{inspect(Enum.take(mismatch_ids, 5))}"
      end

      receive do
        {key, _data} when key in [:registry_pid_insert_hook, :registry_pid_remove_hook] ->
          await_registry_stable_loop(hub_id, child_specs, rf, deadline)

        _other ->
          await_registry_stable_loop(hub_id, child_specs, rf, deadline)
      after
        100 ->
          await_registry_stable_loop(hub_id, child_specs, rf, deadline)
      end
    end
  end
end
