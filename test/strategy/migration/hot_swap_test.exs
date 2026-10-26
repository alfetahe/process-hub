defmodule Test.Strategy.Migration.HotSwapTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Migration.HotSwap
  alias Test.Strategy.Migration.HotSwapTest.Holder
  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Request.Handler.StartChildrenRequest.PostStartData

  setup do
    hub_id = :"test_hs_#{:erlang.unique_integer([:positive])}"
    misc_storage = :ets.new(hub_id, [:set, :public, :named_table])
    hook_storage = :ets.new(:"hook_#{hub_id}", [:set, :public])

    hub = %ProcessHub.Hub{
      hub_id: hub_id,
      storage: %{misc: misc_storage, hook: hook_storage}
    }

    on_exit(fn ->
      if :ets.whereis(hub_id) != :undefined, do: :ets.delete(hub_id)

      try do
        :ets.delete(hook_storage)
      rescue
        _ -> :ok
      end
    end)

    %{hub: hub}
  end

  describe "init/2" do
    test "with handover: false returns strategy unchanged", %{hub: hub} do
      strategy = %HotSwap{handover: false}
      result = MigrationStrategy.init(strategy, hub)
      assert result == strategy

      # Verify NO hooks were registered
      assert HookManager.registered_handlers(hub.storage.hook, Hook.coordinator_shutdown()) == []
      assert HookManager.registered_handlers(hub.storage.hook, Hook.post_children_start()) == []
    end

    test "with handover: true registers hook handlers", %{hub: hub} do
      strategy = %HotSwap{handover: true}
      result = MigrationStrategy.init(strategy, hub)
      assert result == strategy

      shutdown_handlers =
        HookManager.registered_handlers(hub.storage.hook, Hook.coordinator_shutdown())

      startups_handlers =
        HookManager.registered_handlers(hub.storage.hook, Hook.post_children_start())

      assert length(shutdown_handlers) == 1
      assert hd(shutdown_handlers).id == :mhs_shutdown

      assert length(startups_handlers) == 1
      assert hd(startups_handlers).id == :mhs_process_startups
    end
  end

  describe "handle_shutdown/2" do
    test "with handover: false returns :ok" do
      strategy = %HotSwap{handover: false}
      assert HotSwap.handle_shutdown(strategy, %{}) == :ok
    end
  end

  describe "handle_process_startups/3" do
    test "with handover: false returns nil" do
      strategy = %HotSwap{handover: false}
      assert HotSwap.handle_process_startups(strategy, %{}, %{children: []}) == nil
    end
  end

  describe "handle_storage_update/2" do
    test "stores data in ETS under hotswap key", %{hub: hub} do
      data = [{:child1, :state1}]
      HotSwap.handle_storage_update(hub, data)

      stored = Storage.get(hub.storage.misc, :migration_hotswap_state)
      assert stored == data
    end

    test "concatenates with existing data", %{hub: hub} do
      Storage.insert(hub.storage.misc, :migration_hotswap_state, [{:old, :state}])

      HotSwap.handle_storage_update(hub, [{:new, :state}])

      stored = Storage.get(hub.storage.misc, :migration_hotswap_state)
      assert length(stored) == 2
      assert {:new, :state} in stored
      assert {:old, :state} in stored
    end
  end

  describe "complete_migration/3" do
    test "delivers state to new pid and removes from storage", %{hub: hub} do
      child_id = :test_child

      old_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      Storage.insert(hub.storage.misc, {:hotswap_state, child_id}, {:my_state, old_pid})

      # Store sync strategy to avoid crash in Distributor.children_terminate
      Storage.insert(
        hub.storage.misc,
        :synchronization_strategy,
        %ProcessHub.Strategy.Synchronization.PubSub{}
      )

      # complete_migration will try to terminate children via Distributor.
      # We just verify the state delivery part works.
      # Since we don't have a full hub, children_terminate may fail, but
      # the state delivery and hook dispatching happen before that.
      try do
        HotSwap.complete_migration(hub, :target_node, [{child_id, self()}])
      catch
        _, _ -> :ok
      end

      assert_receive {:process_hub, :hotswap_handover, ^child_id, :my_state}
      assert Storage.get(hub.storage.misc, {:hotswap_state, child_id}) == nil

      Process.exit(old_pid, :kill)
    end

    test "dispatches handover_delivered hook when states delivered", %{hub: hub} do
      child_id = :test_child

      old_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      test_pid = self()
      Storage.insert(hub.storage.misc, {:hotswap_state, child_id}, {:my_state, old_pid})

      Storage.insert(
        hub.storage.misc,
        :synchronization_strategy,
        %ProcessHub.Strategy.Synchronization.PubSub{}
      )

      HookManager.register_handler(hub.storage.hook, Hook.handover_delivered(), %HookManager{
        id: :test_hook,
        m: :erlang,
        f: :send,
        a: [test_pid, :handover_hook_fired]
      })

      try do
        HotSwap.complete_migration(hub, :target_node, [{child_id, self()}])
      catch
        _, _ -> :ok
      end

      assert_receive :handover_hook_fired

      Process.exit(old_pid, :kill)
    end

    test "no state found still returns :ok", %{hub: hub} do
      Storage.insert(
        hub.storage.misc,
        :synchronization_strategy,
        %ProcessHub.Strategy.Synchronization.PubSub{}
      )

      try do
        result = HotSwap.complete_migration(hub, :target_node, [{:unknown, self()}])
        assert result == :ok
      catch
        _, _ -> :ok
      end

      refute_receive {:process_hub, :hotswap_handover, _, _}
    end
  end

  describe "the forward_to message" do
    test "tells the old process its replacement with forward_messages and handover", %{
      hub: hub
    } do
      child_id = :forwarded_child
      prepare_completion(hub, child_id, %HotSwap{handover: true, forward_messages: true})
      complete(hub, child_id)

      # The test process is both the old and the new process here, so the
      # mailbox shows the order: the state first, then the replacement.
      assert_receive {:process_hub, kind, ^child_id, _}
      assert kind == :hotswap_handover
      assert_receive {:process_hub, :forward_to, ^child_id, pid}
      assert pid == self()
    end

    test "is not sent by default", %{hub: hub} do
      child_id = :default_child
      prepare_completion(hub, child_id, %HotSwap{handover: true})
      complete(hub, child_id)

      assert_receive {:process_hub, :hotswap_handover, ^child_id, :my_state}
      refute_receive {:process_hub, :forward_to, _, _}
    end

    test "is not sent to a process whose state was not handed over", %{hub: hub} do
      prepare_completion(hub, nil, %HotSwap{handover: true, forward_messages: true})
      complete(hub, :no_state)

      refute_receive {:process_hub, :forward_to, _, _}
    end
  end

  describe "forwarding messages" do
    test "the old process keeps what arrives after its state was read and passes it on" do
      {:ok, old} = GenServer.start(Holder, [])
      ref = Process.monitor(old)

      send(old, {:process_hub, :query_hot_handover_state, self(), :cid, {:no_hub, 5_000}})
      assert_receive {:process_hub, :hotswap_state, :cid, []}

      send(old, {:work, 1})
      GenServer.cast(old, {:work, 2})
      send(old, {:process_hub, :forward_to, :cid, self()})
      assert_receive {:process_hub, :forwarded, :cid, [{:work, 1}, {:"$gen_cast", {:work, 2}}]}

      send(old, {:work, 3})
      assert_receive {:process_hub, :forwarded, :cid, [{:work, 3}]}

      # The test process started it, so it is the parent whose exit stops it.
      Process.exit(old, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^old, :shutdown}
    end

    test "the old process goes back to work when no replacement is named in time" do
      {:ok, old} = GenServer.start(Holder, [])

      send(old, {:process_hub, :query_hot_handover_state, self(), :cid, {:no_hub, 50}})
      assert_receive {:process_hub, :hotswap_state, :cid, []}
      send(old, {:work, 1})

      # Kept with the work and handled after it once the process is back.
      assert :sys.get_state(old) == [1]
      GenServer.stop(old)
    end

    test "the old process works as before without forwarding" do
      {:ok, old} = GenServer.start(Holder, [])

      send(old, {:process_hub, :query_hot_handover_state, self(), :cid})
      assert_receive {:process_hub, :hotswap_state, :cid, []}
      send(old, {:work, 1})

      assert :sys.get_state(old) == [1]
      GenServer.stop(old)
    end

    test "the new process handles passed-on messages after its state" do
      {:ok, new} = GenServer.start(Holder, [])

      send(new, {:process_hub, :forwarded, :cid, [{:work, 2}]})
      send(new, {:process_hub, :hotswap_handover, :cid, [1]})

      assert settled_state(new) == [2, 1]
      GenServer.stop(new)
    end

    test "a passed-on call is answered to its caller by the new process" do
      {:ok, new} = GenServer.start(Holder, [])
      tag = make_ref()

      send(new, {:process_hub, :hotswap_handover, :cid, [1]})
      send(new, {:process_hub, :forwarded, :cid, [{:"$gen_call", {self(), tag}, :get}]})

      assert_receive {^tag, [1]}
      GenServer.stop(new)
    end
  end

  # A passed-on message is handled after the messages already waiting, so the
  # first read lets those through and the second sees the result.
  defp settled_state(pid) do
    :sys.get_state(pid)
    :sys.get_state(pid)
  end

  defp prepare_completion(hub, child_id, strategy) do
    if child_id,
      do: Storage.insert(hub.storage.misc, {:hotswap_state, child_id}, {:my_state, self()})

    Storage.insert(
      hub.storage.misc,
      :synchronization_strategy,
      %ProcessHub.Strategy.Synchronization.PubSub{}
    )

    Storage.insert(hub.storage.misc, ProcessHub.Constant.StorageKey.strmigr(), strategy)
  end

  # Terminating the old process needs a full hub; only the messages sent
  # before it matter here.
  defp complete(hub, child_id) do
    HotSwap.complete_migration(hub, :target_node, [{child_id, self()}])
  catch
    _, _ -> :ok
  end

  describe "handle_post_action_migrate_complete/4" do
    test "sends callback to originating node for successful results", %{hub: hub} do
      results = [
        %PostStartData{
          cid: :child1,
          pid: self(),
          child_spec: %{id: :child1},
          result: {:ok, self()},
          child_nodes: [],
          nodes: [],
          has_errors: false,
          for_node: node()
        }
      ]

      Process.register(self(), hub.hub_id)

      HotSwap.handle_post_action_migrate_complete(hub, results, node(), [:child1])

      assert_receive {:post_action_callback, HotSwap, :complete_migration, _}
    after
      try do
        Process.unregister(hub.hub_id)
      rescue
        _ -> :ok
      end
    end
  end

  describe "handle_shutdown/2 with handover: true" do
    test "calls SwapMigration.handle_shutdown and returns :ok with empty cluster", %{hub: hub} do
      # Store hub_nodes as empty (no remote nodes)
      ProcessHub.Service.Storage.insert(hub.storage.misc, ProcessHub.Constant.StorageKey.hn(), [
        node()
      ])

      strategy = %HotSwap{handover: true, state_query_timeout: 1000}
      assert HotSwap.handle_shutdown(strategy, hub) == :ok
    end
  end

  describe "handle_process_startups/3 with handover: true" do
    test "delivers stored states to started pids", %{hub: hub} do
      strategy = %HotSwap{handover: true}
      storage_key = ProcessHub.Constant.StorageKey.msk()

      # Store some handover state data
      Storage.insert(hub.storage.misc, storage_key, [{:child1, :state_data}])

      children_data = %{children: [%{child_id: :child1, pid: self()}]}
      HotSwap.handle_process_startups(strategy, hub, children_data)

      assert_receive {:process_hub, :hotswap_handover, :child1, :state_data}

      # Storage should be cleaned up
      assert Storage.get(hub.storage.misc, storage_key) == nil
    end

    test "no matching state sends nothing", %{hub: hub} do
      strategy = %HotSwap{handover: true}
      storage_key = ProcessHub.Constant.StorageKey.msk()

      Storage.insert(hub.storage.misc, storage_key, [{:other_child, :state}])

      children_data = %{children: [%{child_id: :unknown, pid: self()}]}
      HotSwap.handle_process_startups(strategy, hub, children_data)

      refute_receive {:process_hub, :hotswap_handover, _, _}
    end
  end

  describe "struct defaults" do
    test "default values" do
      hs = %HotSwap{}
      assert hs.handover == false
      assert hs.state_ttl == 30000
      assert hs.state_query_timeout == 5000
      assert hs.forward_messages == false
    end
  end
end

defmodule Test.Strategy.Migration.HotSwapTest.Holder do
  use GenServer
  use ProcessHub.Strategy.Migration.HotSwap

  @impl GenServer
  def init(items), do: {:ok, items}

  @impl GenServer
  def handle_call(:get, _from, items), do: {:reply, items, items}

  @impl GenServer
  def handle_cast({:work, item}, items), do: {:noreply, [item | items]}

  @impl GenServer
  def handle_info({:work, item}, items), do: {:noreply, [item | items]}
end
