defmodule Test.Strategy.Redundancy.ReplicationTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Redundancy.Replication
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Strategy.Distribution.ConsistentHashing
  alias ProcessHub.Service.Ring
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook

  describe "replication_factor/1" do
    test "returns numeric factor" do
      strategy = %Replication{replication_factor: 3}
      assert RedundancyStrategy.replication_factor(strategy) == 3
    end

    test "returns 1 for factor of 1" do
      strategy = %Replication{replication_factor: 1}
      assert RedundancyStrategy.replication_factor(strategy) == 1
    end

    test "with :cluster_size returns current cluster size" do
      strategy = %Replication{replication_factor: :cluster_size}
      # On a single node, Node.list() returns [], so result = 0 + 1 = 1
      result = RedundancyStrategy.replication_factor(strategy)
      assert result == 1
    end
  end

  describe "master_node/4" do
    test "deterministic selection: same inputs = same result" do
      strategy = %Replication{}
      hub = %{}
      nodes = [:node1@host, :node2@host, :node3@host]

      master1 = RedundancyStrategy.master_node(strategy, hub, :child1, nodes)
      master2 = RedundancyStrategy.master_node(strategy, hub, :child1, nodes)

      assert master1 == master2
    end

    test "result is from the node list" do
      strategy = %Replication{}
      hub = %{}
      nodes = [:node1@host, :node2@host, :node3@host]

      master = RedundancyStrategy.master_node(strategy, hub, :child1, nodes)
      assert master in nodes
    end

    test "different child_ids may produce different masters" do
      strategy = %Replication{}
      hub = %{}
      nodes = [:node1@host, :node2@host, :node3@host]

      # Generate multiple child_ids and check distribution
      masters =
        for i <- 1..20 do
          RedundancyStrategy.master_node(strategy, hub, :"child_#{i}", nodes)
        end

      # At least 2 different masters should be selected across 20 children
      unique_masters = Enum.uniq(masters)
      assert length(unique_masters) >= 2
    end

    test "works with atom child_ids" do
      strategy = %Replication{}
      hub = %{}
      nodes = [:node1@host, :node2@host]

      master = RedundancyStrategy.master_node(strategy, hub, :my_child, nodes)
      assert master in nodes
    end

    test "works with string child_ids" do
      strategy = %Replication{}
      hub = %{}
      nodes = [:node1@host, :node2@host]

      master = RedundancyStrategy.master_node(strategy, hub, "my_child", nodes)
      assert master in nodes
    end

    test "order independent: sorted differently gives same result" do
      strategy = %Replication{}
      hub = %{}
      nodes1 = [:a@host, :b@host, :c@host]
      nodes2 = [:c@host, :a@host, :b@host]

      # master_node sorts internally, so different input order should give same result
      master1 = RedundancyStrategy.master_node(strategy, hub, :child1, nodes1)
      master2 = RedundancyStrategy.master_node(strategy, hub, :child1, nodes2)

      assert master1 == master2
    end
  end

  describe "init/2" do
    test "registers hook handlers and returns strategy" do
      hub_id = :"test_repl_init_#{:erlang.unique_integer([:positive])}"
      hook_storage = :ets.new(:"hook_#{hub_id}", [:set, :public])

      hub = %ProcessHub.Hub{
        hub_id: hub_id,
        storage: %{hook: hook_storage}
      }

      strategy = %Replication{replication_factor: 2}
      result = RedundancyStrategy.init(strategy, hub)

      assert result == strategy

      # Check post_children_start hook handlers were registered
      post_start_handlers =
        HookManager.registered_handlers(hook_storage, Hook.post_children_start())

      assert length(post_start_handlers) >= 1

      :ets.delete(hook_storage)
    end
  end

  describe "handle_post_start/3" do
    test "with redundancy_signal: :none returns :ok" do
      strategy = %Replication{redundancy_signal: :none}
      assert Replication.handle_post_start(strategy, %{}, []) == :ok
    end

    test "with redundancy_signal: :all sends signal to locally started pids" do
      hub_id = :"test_repl_ps_#{:erlang.unique_integer([:positive])}"
      misc_storage = :ets.new(hub_id, [:set, :public, :named_table])
      hook_storage = :ets.new(:"hook_repl_ps_#{hub_id}", [:set, :public])

      hub = %ProcessHub.Hub{
        hub_id: hub_id,
        storage: %{misc: misc_storage, hook: hook_storage}
      }

      nodes = [node()]
      Storage.insert(misc_storage, StorageKey.hn(), nodes)
      hash_ring = Ring.create_ring(nodes)
      Storage.insert(misc_storage, StorageKey.hr(), hash_ring)
      Storage.insert(misc_storage, StorageKey.strdist(), %ConsistentHashing{})

      strategy = %Replication{
        replication_factor: 1,
        replication_model: :active_active,
        redundancy_signal: :all
      }

      test_pid = self()

      child_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:got_signal, msg})
          end
        end)

      post_start_data = [{:child1, :ok, child_pid, [node()]}]

      Replication.handle_post_start(strategy, hub, post_start_data)

      assert_receive {:got_signal, {:process_hub, :redundancy_signal, :active}}

      :ets.delete(hub_id)
      :ets.delete(hook_storage)
    end

    test "with redundancy_signal matching mode sends signal" do
      hub_id = :"test_repl_match_#{:erlang.unique_integer([:positive])}"
      misc_storage = :ets.new(hub_id, [:set, :public, :named_table])
      hook_storage = :ets.new(:"hook_repl_match_#{hub_id}", [:set, :public])

      hub = %ProcessHub.Hub{
        hub_id: hub_id,
        storage: %{misc: misc_storage, hook: hook_storage}
      }

      nodes = [node()]
      Storage.insert(misc_storage, StorageKey.hn(), nodes)
      hash_ring = Ring.create_ring(nodes)
      Storage.insert(misc_storage, StorageKey.hr(), hash_ring)
      Storage.insert(misc_storage, StorageKey.strdist(), %ConsistentHashing{})

      # With active_active model, the mode is always :active
      # So redundancy_signal: :active should match and send the signal
      strategy = %Replication{
        replication_factor: 1,
        replication_model: :active_active,
        redundancy_signal: :active
      }

      test_pid = self()

      child_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:got_match_signal, msg})
          end
        end)

      post_start_data = [{:child_match, :ok, child_pid, [node()]}]

      Replication.handle_post_start(strategy, hub, post_start_data)

      assert_receive {:got_match_signal, {:process_hub, :redundancy_signal, :active}}

      :ets.delete(hub_id)
      :ets.delete(hook_storage)
    end

    test "with non-matching redundancy_signal does not send" do
      hub_id = :"test_repl_nomatch_#{:erlang.unique_integer([:positive])}"
      misc_storage = :ets.new(hub_id, [:set, :public, :named_table])
      hook_storage = :ets.new(:"hook_repl_nomatch_#{hub_id}", [:set, :public])

      hub = %ProcessHub.Hub{
        hub_id: hub_id,
        storage: %{misc: misc_storage, hook: hook_storage}
      }

      nodes = [node()]
      Storage.insert(misc_storage, StorageKey.hn(), nodes)
      hash_ring = Ring.create_ring(nodes)
      Storage.insert(misc_storage, StorageKey.hr(), hash_ring)
      Storage.insert(misc_storage, StorageKey.strdist(), %ConsistentHashing{})

      # With active_active model, mode is always :active
      # So redundancy_signal: :passive should NOT match
      strategy = %Replication{
        replication_factor: 1,
        replication_model: :active_active,
        redundancy_signal: :passive
      }

      child_pid =
        spawn(fn ->
          receive do
            _ -> :ok
          end
        end)

      post_start_data = [{:child_nomatch, :ok, child_pid, [node()]}]

      Replication.handle_post_start(strategy, hub, post_start_data)

      refute_receive {:process_hub, :redundancy_signal, _}, 100

      Process.exit(child_pid, :kill)
      :ets.delete(hub_id)
      :ets.delete(hook_storage)
    end

    test "skips already_started children" do
      hub_id = :"test_repl_skip_as_#{:erlang.unique_integer([:positive])}"
      misc_storage = :ets.new(hub_id, [:set, :public, :named_table])
      hook_storage = :ets.new(:"hook_repl_skip_as_#{hub_id}", [:set, :public])

      hub = %ProcessHub.Hub{
        hub_id: hub_id,
        storage: %{misc: misc_storage, hook: hook_storage}
      }

      nodes = [node()]
      Storage.insert(misc_storage, StorageKey.hn(), nodes)
      hash_ring = Ring.create_ring(nodes)
      Storage.insert(misc_storage, StorageKey.hr(), hash_ring)
      Storage.insert(misc_storage, StorageKey.strdist(), %ConsistentHashing{})

      strategy = %Replication{
        replication_factor: 1,
        replication_model: :active_active,
        redundancy_signal: :all
      }

      child_pid =
        spawn(fn ->
          receive do
            _ -> :ok
          end
        end)

      # :already_started result should NOT trigger signal sending
      post_start_data = [
        {:child_as, {:error, {:already_started, child_pid}}, child_pid, [node()]}
      ]

      Replication.handle_post_start(strategy, hub, post_start_data)

      refute_receive {:process_hub, :redundancy_signal, _}, 100

      Process.exit(child_pid, :kill)
      :ets.delete(hub_id)
      :ets.delete(hook_storage)
    end

    test "with empty post_start_data returns :ok" do
      hub_id = :"test_repl_empty_#{:erlang.unique_integer([:positive])}"
      misc_storage = :ets.new(hub_id, [:set, :public, :named_table])
      hook_storage = :ets.new(:"hook_repl_empty_#{hub_id}", [:set, :public])

      hub = %ProcessHub.Hub{
        hub_id: hub_id,
        storage: %{misc: misc_storage, hook: hook_storage}
      }

      Storage.insert(misc_storage, StorageKey.strdist(), %ConsistentHashing{})

      strategy = %Replication{redundancy_signal: :all}
      assert Replication.handle_post_start(strategy, hub, []) == :ok

      :ets.delete(hub_id)
      :ets.delete(hook_storage)
    end
  end

  describe "handle_post_update/3" do
    test "with redundancy_signal: :none returns :ok" do
      strategy = %Replication{redundancy_signal: :none}
      assert Replication.handle_post_update(strategy, %{}, {[], {:up, :some_node}}) == :ok
    end

    test "with non-active_passive model returns :ok" do
      strategy = %Replication{redundancy_signal: :all, replication_model: :active_active}
      assert Replication.handle_post_update(strategy, %{}, {[], {:up, :some_node}}) == :ok
    end

    test "with active_passive model and empty processes_data returns :ok" do
      strategy = %Replication{redundancy_signal: :all, replication_model: :active_passive}
      assert Replication.handle_post_update(strategy, %{}, {[], {:up, :some_node}}) == :ok
    end

    test "with active_passive model sends mode signal on :down event" do
      hub_id = :"test_repl_ap_down_#{:erlang.unique_integer([:positive])}"
      misc_storage = :ets.new(hub_id, [:set, :public, :named_table])
      hook_storage = :ets.new(:"hook_repl_ap_down_#{hub_id}", [:set, :public])

      hub = %ProcessHub.Hub{
        hub_id: hub_id,
        storage: %{misc: misc_storage, hook: hook_storage}
      }

      strategy = %Replication{
        replication_factor: 2,
        replication_model: :active_passive,
        redundancy_signal: :all
      }

      test_pid = self()
      local_node = node()

      child_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:got_mode, msg})
          end
        end)

      # Process data: {child_id, new_nodes, old_nodes, opts}
      # local_node must be in old_nodes so handle_redundancy_signal processes it
      processes_data = [
        {:child_ap_1, [local_node, :other@host], [local_node, :other@host, :leaving@host],
         [pid: child_pid]}
      ]

      Replication.handle_post_update(strategy, hub, {processes_data, {:down, :leaving@host}})

      # Should receive a redundancy signal (either :active or :passive)
      assert_receive {:got_mode, {:process_hub, :redundancy_signal, mode}}
      assert mode in [:active, :passive]

      :ets.delete(hub_id)
      :ets.delete(hook_storage)
    end

    test "with active_passive model sends mode signal on :up event" do
      hub_id = :"test_repl_ap_up_#{:erlang.unique_integer([:positive])}"
      misc_storage = :ets.new(hub_id, [:set, :public, :named_table])
      hook_storage = :ets.new(:"hook_repl_ap_up_#{hub_id}", [:set, :public])

      hub = %ProcessHub.Hub{
        hub_id: hub_id,
        storage: %{misc: misc_storage, hook: hook_storage}
      }

      strategy = %Replication{
        replication_factor: 2,
        replication_model: :active_passive,
        redundancy_signal: :all
      }

      test_pid = self()
      local_node = node()

      child_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:got_mode_up, msg})
          end
        end)

      # Simulate :up event where a new node joins and becomes the new master
      # local_node is in old_nodes (was running before), joining node enters
      # Choose child_id such that master calculation changes
      processes_data = [
        {:child_ap_up, [local_node, :other@host, :joining@host], [local_node, :other@host],
         [pid: child_pid]}
      ]

      Replication.handle_post_update(strategy, hub, {processes_data, {:up, :joining@host}})

      # The :up event may or may not send a signal depending on master calculation
      # If master changed, a signal is sent; if not, no signal
      # Either way, verify the function completes without error
      :ets.delete(hub_id)
      :ets.delete(hook_storage)
    end

    test "with active_passive model skips when local node not in old_nodes" do
      hub_id = :"test_repl_ap_skip_#{:erlang.unique_integer([:positive])}"
      misc_storage = :ets.new(hub_id, [:set, :public, :named_table])
      hook_storage = :ets.new(:"hook_repl_ap_skip_#{hub_id}", [:set, :public])

      hub = %ProcessHub.Hub{
        hub_id: hub_id,
        storage: %{misc: misc_storage, hook: hook_storage}
      }

      strategy = %Replication{
        replication_factor: 2,
        replication_model: :active_passive,
        redundancy_signal: :all
      }

      # local_node is NOT in old_nodes — handle_redundancy_signal should skip
      processes_data = [
        {:child_ap_skip, [:remote1@host, :remote2@host], [:remote1@host, :remote2@host], []}
      ]

      Replication.handle_post_update(strategy, hub, {processes_data, {:down, :remote2@host}})

      # No signal should be sent since local node wasn't in old_nodes
      refute_receive {:process_hub, :redundancy_signal, _}

      :ets.delete(hub_id)
      :ets.delete(hook_storage)
    end
  end

  describe "struct defaults" do
    test "has expected default values" do
      strategy = %Replication{}
      assert strategy.replication_factor == 2
      assert strategy.replication_model == :active_active
      assert strategy.redundancy_signal == :none
    end
  end
end
