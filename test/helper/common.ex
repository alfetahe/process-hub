# Required for Elixir < 1.13
ExUnit.start()

defmodule Test.Helper.Common do
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Service.Ring
  alias ProcessHub.Constant.Hook
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

  def validate_registry_length(%{hub_id: hub_id, hub: hub} = context, child_specs) do
    registry = ProcessHub.registry_dump(hub_id) |> Map.to_list()

    child_spec_len = length(child_specs)
    registry_len = length(registry)

    if registry_len !== child_spec_len do
      # Find missing children
      registry_ids = Enum.map(registry, fn {id, _} -> id end) |> MapSet.new()
      expected_ids = Enum.map(child_specs, & &1.id) |> MapSet.new()

      missing = MapSet.difference(expected_ids, registry_ids) |> MapSet.to_list()
      extra = MapSet.difference(registry_ids, expected_ids) |> MapSet.to_list()

      IO.puts("\n=== DEBUG: Registry Length Mismatch ===")
      IO.puts("Expected: #{child_spec_len}, Actual: #{registry_len}")
      IO.puts("Missing count: #{length(missing)}")
      IO.puts("Extra count: #{length(extra)}")

      if length(missing) > 0 do
        IO.puts("\nFirst 10 missing child_ids:")
        Enum.take(missing, 10) |> Enum.each(&IO.inspect/1)

        # Debug: Check all nodes for missing children
        debug_missing_children(context, missing, 5)
      end

      if length(extra) > 0 do
        IO.puts("\nFirst 10 extra child_ids:")
        Enum.take(extra, 10) |> Enum.each(&IO.inspect/1)
      end

      IO.puts("=======================================\n")
    end

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
    # TODO: remove later.
    opts = Keyword.put_new(opts, :timeout, 15_000)

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

  # TODO: remove later.
  def await_registry_stable(context, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15000)
    poll_interval = Keyword.get(opts, :poll_interval, 300)
    stable_period = Keyword.get(opts, :stable_period, 500)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_await_registry_stable(context, deadline, poll_interval, stable_period, nil)
  end

  defp do_await_registry_stable(context, deadline, poll_interval, stable_period, stable_since) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      # Log what's still wrong for debugging
      case check_registry_stable(context) do
        {:error, errors} ->
          IO.puts("Registry stability timeout. Sample errors (first 5):")
          Enum.take(errors, 5) |> Enum.each(&IO.inspect/1)

        _ ->
          :ok
      end

      {:error, :timeout}
    else
      case check_registry_stable(context) do
        :ok ->
          # Registry is stable now - check if it's been stable long enough
          stable_since = stable_since || now

          if now - stable_since >= stable_period do
            :ok
          else
            receive_wait(poll_interval)

            do_await_registry_stable(
              context,
              deadline,
              poll_interval,
              stable_period,
              stable_since
            )
          end

        {:error, _reason} ->
          # Registry not stable - reset stable_since
          receive_wait(poll_interval)
          do_await_registry_stable(context, deadline, poll_interval, stable_period, nil)
      end
    end
  end

  # Use receive with timeout as a non-blocking wait mechanism
  defp receive_wait(timeout) do
    ref = make_ref()

    receive do
      {:__await_registry_stable_wait__, ^ref} -> :ok
    after
      timeout -> :ok
    end
  end

  defp check_registry_stable(%{hub_id: hub_id, hub_conf: hub_conf, hub: hub} = _context) do
    registry = ProcessHub.registry_dump(hub_id)
    replication_factor = RedundancyStrategy.replication_factor(hub_conf.redundancy_strategy)

    if Enum.empty?(registry) do
      :ok
    else
      # Use the same approach as validate_replication - get ring directly
      ring = Ring.get_ring(hub.storage.misc)

      errors =
        Enum.reduce(registry, [], fn {child_id, {_cs, nodes, _meta}}, acc ->
          ring_nodes = Ring.key_to_nodes(ring, child_id, replication_factor)
          actual_nodes = Keyword.keys(nodes)

          cond do
            length(nodes) != replication_factor ->
              [{:wrong_count, child_id, length(nodes), replication_factor} | acc]

            not Enum.all?(actual_nodes, &Enum.member?(ring_nodes, &1)) ->
              [{:wrong_nodes, child_id, actual_nodes, ring_nodes} | acc]

            not Enum.all?(ring_nodes, &Enum.member?(actual_nodes, &1)) ->
              [{:missing_nodes, child_id, actual_nodes, ring_nodes} | acc]

            true ->
              acc
          end
        end)

      if Enum.empty?(errors) do
        :ok
      else
        {:error, errors}
      end
    end
  end

  def debug_missing_children(
        %{hub_id: hub_id, hub: hub, hub_conf: hub_conf} = _context,
        missing_cids,
        sample_size \\ 3
      ) do
    all_nodes = [node() | Node.list()]
    dist_sup = hub.procs.dist_sup
    dist_strat = hub_conf.distribution_strategy
    rf = RedundancyStrategy.replication_factor(hub_conf.redundancy_strategy)
    sample = Enum.take(missing_cids, sample_size)

    IO.puts("\n=== DEBUG: Analyzing #{length(sample)} missing children ===")
    IO.puts("Cluster nodes: #{inspect(all_nodes)}")
    IO.puts("Replication factor: #{rf}\n")

    # Check distribution signature consistency
    IO.puts("--- Distribution Signatures ---")
    local_sig = DistributionStrategy.distribution_signature(dist_strat, hub)
    IO.puts("  #{node()}: #{local_sig}")

    Enum.each(Node.list(), fn n ->
      remote_sig =
        :erpc.call(
          n,
          fn ->
            # Get hub fresh on remote node
            remote_hub = ProcessHub.Coordinator.get_hub(hub_id)

            remote_dist_strat =
              ProcessHub.Service.Storage.get(
                remote_hub.storage.misc,
                ProcessHub.Constant.StorageKey.strdist()
              )

            DistributionStrategy.distribution_signature(remote_dist_strat, remote_hub)
          end,
          5000
        )

      match = if remote_sig == local_sig, do: "OK", else: "MISMATCH!"
      IO.puts("  #{n}: #{remote_sig} #{match}")
    end)

    IO.puts("")

    Enum.each(sample, fn cid ->
      IO.puts("--- Child: #{cid} ---")

      # Where should it be according to local node?
      local_targets =
        DistributionStrategy.belongs_to(dist_strat, hub, [cid], rf)
        |> Enum.find(fn {id, _} -> id == cid end)
        |> elem(1)

      IO.puts("  Local belongs_to: #{inspect(local_targets)}")

      # Check each target node - is child there?
      Enum.each(local_targets, fn target ->
        {in_sup, in_reg} =
          if target == node() do
            sup_children = Supervisor.which_children(dist_sup)
            in_supervisor = Enum.any?(sup_children, fn {id, _, _, _} -> id == cid end)
            in_registry = ProcessHub.Service.ProcessRegistry.lookup(hub_id, cid) != nil
            {in_supervisor, in_registry}
          else
            :erpc.call(
              target,
              fn ->
                # Get hub fresh on remote node
                remote_hub = ProcessHub.Coordinator.get_hub(hub_id)
                sup_children = Supervisor.which_children(remote_hub.procs.dist_sup)
                in_supervisor = Enum.any?(sup_children, fn {id, _, _, _} -> id == cid end)
                in_registry = ProcessHub.Service.ProcessRegistry.lookup(hub_id, cid) != nil
                {in_supervisor, in_registry}
              end,
              5000
            )
          end

        IO.puts("    #{target}: sup=#{in_sup}, reg=#{in_reg}")
      end)

      # Check what OTHER nodes think belongs_to returns
      IO.puts("  Remote belongs_to calculations:")

      Enum.each(Node.list() |> Enum.take(3), fn n ->
        remote_targets =
          :erpc.call(
            n,
            fn ->
              # Get hub fresh on remote node
              remote_hub = ProcessHub.Coordinator.get_hub(hub_id)

              DistributionStrategy.belongs_to(dist_strat, remote_hub, [cid], rf)
              |> Enum.find(fn {id, _} -> id == cid end)
              |> elem(1)
            end,
            5000
          )

        match = if remote_targets == local_targets, do: "OK", else: "DIFFERENT!"
        IO.puts("    #{n}: #{inspect(remote_targets)} #{match}")
      end)

      IO.puts("")
    end)

    IO.puts("=== END DEBUG ===\n")
  end
end
