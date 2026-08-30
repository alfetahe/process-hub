defmodule Test.Service.MigrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Coordinator
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Migration
  alias ProcessHub.Service.Ring
  alias ProcessHub.Service.Storage
  alias ProcessHub.Strategy.Distribution.ConsistentHashing
  alias ProcessHub.Strategy.Migration.HotSwap
  alias ProcessHub.Strategy.Migration.MigrationConsent
  alias ProcessHub.Strategy.Redundancy.Replication
  alias ProcessHub.Strategy.Redundancy.Singularity
  alias ProcessHub.Strategy.Synchronization.PubSub
  alias Test.Helper.ConsentServer

  @remote_node :ph_fake_remote@localhost

  # Stands in for the coordinator: resolves the hub, serializes deferred-list
  # writes, and forwards the messages it would receive to the test process.
  defmodule HubStub do
    @moduledoc false
    use GenServer

    def start_link({hub, owner}),
      do: GenServer.start_link(__MODULE__, {hub, owner}, name: hub.hub_id)

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_call(:get_state, _from, {hub, _owner} = state), do: {:reply, hub, state}

    @impl GenServer
    def handle_call({:migration_deferred_update, fun}, _from, {hub, _owner} = state) do
      {:reply, Migration.apply_deferred_update(hub, fun), state}
    end

    @impl GenServer
    def handle_info(msg, {_hub, owner} = state) do
      send(owner, msg)
      {:noreply, state}
    end
  end

  setup do
    hub_id = :"test_migration_#{:erlang.unique_integer([:positive])}"
    event_queue = :"#{hub_id}_eq"
    task_sup = :"#{hub_id}_tasks"
    system_registry = :"#{hub_id}_sysreg"

    # The registry storage is the named table matching the hub id.
    :ets.new(hub_id, [:set, :public, :named_table])
    misc = :ets.new(:"#{hub_id}_misc", [:set, :public])
    hook = :ets.new(:"#{hub_id}_hook", [:set, :public])

    start_supervised!({:blockade, %{name: event_queue, priority_sync: false}})
    start_supervised!({Task.Supervisor, name: task_sup})
    start_supervised!({Registry, keys: :unique, name: system_registry})

    Storage.insert(misc, StorageKey.hn(), [node(), @remote_node])
    Storage.insert(misc, StorageKey.hr(), Ring.create_ring([@remote_node]))
    Storage.insert(misc, StorageKey.strdist(), %ConsistentHashing{})
    Storage.insert(misc, StorageKey.strred(), %Singularity{})
    Storage.insert(misc, StorageKey.strsyn(), %PubSub{})

    Storage.insert(misc, StorageKey.strmigr(), %HotSwap{
      handover: true,
      state_query_timeout: 500,
      consent_settings: %MigrationConsent{consent_timeout: 100}
    })

    hub = %ProcessHub.Hub{
      hub_id: hub_id,
      procs: %{event_queue: event_queue, task_sup: task_sup, system_registry: system_registry},
      storage: %{misc: misc, hook: hook}
    }

    start_supervised!({HubStub, {hub, self()}})

    on_exit(fn ->
      if :ets.whereis(hub_id) != :undefined, do: :ets.delete(hub_id)
    end)

    %{hub: hub}
  end

  defp register_child(hub, child_id, pid) do
    cspec = %{id: child_id, start: {ConsentServer, :start_link, [%{}]}}
    Storage.insert(hub.hub_id, child_id, {cspec, [{node(), pid}], %{}})
    cspec
  end

  defp put_deferred(hub, entries) do
    Storage.insert(hub.storage.misc, StorageKey.mdl(), entries)
  end

  defp entry(child_id, opts \\ []) do
    %{
      child_id: child_id,
      deferred_at: Keyword.get(opts, :deferred_at, System.monotonic_time(:millisecond)),
      ready: Keyword.get(opts, :ready, false)
    }
  end

  defp recv_hook(hub, hook_key) do
    HookManager.register_handler(hub.storage.hook, hook_key, %HookManager{
      id: :"test_#{hook_key}",
      m: :erlang,
      f: :send,
      a: [self(), :_]
    })
  end

  describe "defer_children/2" do
    test "adds entries once and dispatches the migration_deferred hook", %{hub: hub} do
      recv_hook(hub, Hook.migration_deferred())

      assert Migration.defer_children(hub, [:a, :b]) == :ok
      assert_receive %{child_ids: [:a, :b]}

      assert [%{child_id: :a, ready: false}, %{child_id: :b, ready: false}] =
               Migration.deferred_list(hub)

      # Re-deferring an already-parked child adds no duplicate entry.
      assert Migration.defer_children(hub, [:b, :c]) == :ok
      assert_receive %{child_ids: [:c]}
      assert Enum.map(Migration.deferred_list(hub), & &1.child_id) == [:a, :b, :c]
    end

    test "notifies the coordinator to schedule the retry tick", %{hub: hub} do
      Migration.defer_children(hub, [:a])

      assert_receive {:migration_retry_ensure, 10_000}
    end

    test "empty list is a no-op", %{hub: hub} do
      recv_hook(hub, Hook.migration_deferred())

      assert Migration.defer_children(hub, []) == :ok
      assert Migration.deferred_list(hub) == []
      refute_received %{child_ids: _}
    end
  end

  describe "migration_ready/2" do
    test "unknown child returns error and changes nothing", %{hub: hub} do
      put_deferred(hub, [entry(:a)])

      assert Migration.migration_ready(hub, :unknown) == {:error, :not_deferred}
      assert [%{child_id: :a, ready: false}] = Migration.deferred_list(hub)
    end

    test "marks the entry ready and requests an immediate tick", %{hub: hub} do
      put_deferred(hub, [entry(:a), entry(:b)])

      assert Migration.migration_ready(hub, :a) == :ok

      assert [%{child_id: :a, ready: true}, %{child_id: :b, ready: false}] =
               Migration.deferred_list(hub)

      assert_receive {:migration_retry_ensure, 0}
    end

    test "resolves the hub via the coordinator when given a hub id", %{hub: hub} do
      assert Migration.migration_ready(hub.hub_id, :unknown) == {:error, :not_deferred}
    end
  end

  describe "migrate_child/3" do
    test "moves a locally hosted child to the target through the handover pipeline", %{hub: hub} do
      {:ok, pid} = ConsentServer.start_link(%{})
      register_child(hub, :mc1, pid)

      assert :ok = Migration.migrate_child(hub.hub_id, :mc1, @remote_node)
      # The hot-swap handover pipeline ran (state queried and stored) without
      # any deferred-list involvement — consent is the caller's decision here.
      assert {%{}, ^pid} = Storage.get(hub.storage.misc, {:hotswap_state, :mc1})
      assert Migration.deferred_list(hub) == []
    end

    test "refuses an unknown child, a non-member target, and a same-node move", %{hub: hub} do
      assert {:error, :not_found} = Migration.migrate_child(hub.hub_id, :missing, @remote_node)

      {:ok, pid} = ConsentServer.start_link(%{})
      register_child(hub, :mc2, pid)

      assert {:error, :not_a_member} =
               Migration.migrate_child(hub.hub_id, :mc2, :not_in_hub@nowhere)

      assert {:error, :same_node} = Migration.migrate_child(hub.hub_id, :mc2, node())
      assert Storage.get(hub.storage.misc, {:hotswap_state, :mc2}) == nil
    end
  end

  describe "handle_retry_tick/1" do
    test "prunes entries whose child has no local pid", %{hub: hub} do
      put_deferred(hub, [entry(:ghost)])

      assert Migration.handle_retry_tick(hub) == 0
      assert Migration.deferred_list(hub) == []
    end

    test "prunes entries reassigned to the local node", %{hub: hub} do
      {:ok, pid} = ConsentServer.start_link(%{})
      register_child(hub, :c1, pid)
      Storage.insert(hub.storage.misc, StorageKey.hr(), Ring.create_ring([node()]))
      put_deferred(hub, [entry(:c1, ready: true)])

      assert Migration.handle_retry_tick(hub) == 0
      assert Migration.deferred_list(hub) == []
      # Pruned, not migrated: no handover state was queried or stored.
      assert Storage.get(hub.storage.misc, {:hotswap_state, :c1}) == nil
      assert Process.alive?(pid)
    end

    test "migrates ready entries to the target recomputed at tick time", %{hub: hub} do
      {:ok, pid} = ConsentServer.start_link(%{consent_reply: :defer})
      register_child(hub, :c1, pid)
      put_deferred(hub, [entry(:c1, ready: true)])

      assert Migration.handle_retry_tick(hub) == 0
      assert Migration.deferred_list(hub) == []
      # The hot-swap handover pipeline ran (state queried and stored).
      assert {%{}, ^pid} = Storage.get(hub.storage.misc, {:hotswap_state, :c1})
    end

    test "re-queried children replying :defer stay deferred", %{hub: hub} do
      {:ok, pid} = ConsentServer.start_link(%{consent_reply: :defer})
      register_child(hub, :c1, pid)
      put_deferred(hub, [entry(:c1)])

      assert Migration.handle_retry_tick(hub) == 1
      assert [%{child_id: :c1}] = Migration.deferred_list(hub)
      assert Storage.get(hub.storage.misc, {:hotswap_state, :c1}) == nil
    end

    test "re-queried children replying :ready migrate", %{hub: hub} do
      {:ok, pid} = ConsentServer.start_link(%{consent_reply: :ready})
      register_child(hub, :c1, pid)
      put_deferred(hub, [entry(:c1)])

      assert Migration.handle_retry_tick(hub) == 0
      assert Migration.deferred_list(hub) == []
      assert {%{}, ^pid} = Storage.get(hub.storage.misc, {:hotswap_state, :c1})
    end

    test "entries exceeding max_defer_time are force-migrated with a warning", %{hub: hub} do
      {:ok, pid} = ConsentServer.start_link(%{consent_reply: :defer})
      register_child(hub, :c1, pid)
      expired_at = System.monotonic_time(:millisecond) - 700_000
      put_deferred(hub, [entry(:c1, deferred_at: expired_at)])

      log =
        capture_log(fn ->
          assert Migration.handle_retry_tick(hub) == 0
        end)

      assert log =~ "Force-migrating deferred children"
      assert Migration.deferred_list(hub) == []
      assert {%{}, ^pid} = Storage.get(hub.storage.misc, {:hotswap_state, :c1})
    end

    test "notifies the drain waiter when the list empties", %{hub: hub} do
      {:ok, pid} = ConsentServer.start_link(%{})
      register_child(hub, :c1, pid)
      put_deferred(hub, [entry(:c1, ready: true)])
      Storage.insert(hub.storage.misc, StorageKey.drn(), %{waiter: self()})

      # Ticks run off-process (a coordinator task); the waiter never self-notifies.
      assert Task.await(Task.async(fn -> Migration.handle_retry_tick(hub) end)) == 0
      assert_receive :ph_drain_deferred_empty
    end

    test "keeps handling a deferred child whose local node is only a replica target",
         %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.strred(), %Replication{replication_factor: 2})
      ring = Ring.create_ring([node(), @remote_node])
      Storage.insert(hub.storage.misc, StorageKey.hr(), ring)

      # A child whose PRIMARY is the remote node, while the local node remains a
      # secondary (replica) target.
      cid =
        Enum.find([:a, :b, :c, :d, :e, :f, :g, :h], fn c ->
          Ring.key_to_nodes(ring, c, 2) == [@remote_node, node()]
        end)

      test_pid = self()

      child =
        spawn(fn ->
          receive do
            {:process_hub, :migration_consent, reply_to, ^cid} ->
              send(test_pid, :consent_queried)
              send(reply_to, {:process_hub, :migration_consent_reply, cid, :defer})
          end
        end)

      register_child(hub, cid, child)
      put_deferred(hub, [entry(cid)])

      # It must still be consent-queried and stay parked — never silently dropped.
      assert Migration.handle_retry_tick(hub) == 1
      assert_received :consent_queried
      assert [%{child_id: ^cid}] = Migration.deferred_list(hub)
    end

    test "migrating a replica-target child does not stop it locally", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.strred(), %Replication{replication_factor: 2})
      ring = Ring.create_ring([node(), @remote_node])
      Storage.insert(hub.storage.misc, StorageKey.hr(), ring)

      cid =
        Enum.find([:a, :b, :c, :d, :e, :f, :g, :h], fn c ->
          Ring.key_to_nodes(ring, c, 2) == [@remote_node, node()]
        end)

      {:ok, pid} = ConsentServer.start_link(%{})
      register_child(hub, cid, pid)
      put_deferred(hub, [entry(cid, ready: true)])

      assert Migration.handle_retry_tick(hub) == 0
      assert Migration.deferred_list(hub) == []
      # Local node is still a target, so it is not in `stop_local`: no handover
      # query, no termination — only the primary moves.
      assert Storage.get(hub.storage.misc, {:hotswap_state, cid}) == nil
      assert Process.alive?(pid)
    end

    test "a concurrent defer is not clobbered by an in-flight tick", %{hub: hub} do
      test_pid = self()

      # Never answers the handover query, so the tick stalls inside collect_states.
      stalling_child =
        spawn(fn ->
          receive do
            {:process_hub, :query_hot_handover_state, _reply_to, _cid} ->
              send(test_pid, :tick_in_flight)
              receive do: (:never -> :ok)
          end
        end)

      register_child(hub, :c1, stalling_child)
      put_deferred(hub, [entry(:c1, ready: true)])

      task = Task.async(fn -> Migration.handle_retry_tick(hub) end)
      assert_receive :tick_in_flight

      Migration.defer_children(hub, [:c2])
      Task.await(task, 5_000)

      assert Enum.map(Migration.deferred_list(hub), & &1.child_id) == [:c2]
    end
  end

  describe "coordinator retry scheduling" do
    test "schedules no timer while the deferred list is empty", %{hub: hub} do
      assert {:noreply, state} = Coordinator.handle_info({:migration_retry_ensure, 0}, hub)
      assert state.migration_retry_timer == nil
      refute_receive :migration_retry_tick, 50
    end

    test "schedules a tick when entries exist", %{hub: hub} do
      put_deferred(hub, [entry(:a)])

      assert {:noreply, state} = Coordinator.handle_info({:migration_retry_ensure, 0}, hub)
      assert is_reference(state.migration_retry_timer)
      assert_receive :migration_retry_tick
    end

    test "does not double-schedule while a timer is pending or a tick runs", %{hub: hub} do
      put_deferred(hub, [entry(:a)])
      state = %{hub | migration_retry_timer: make_ref()}

      assert {:noreply, ^state} = Coordinator.handle_info({:migration_retry_ensure, 0}, state)
      refute_receive :migration_retry_tick, 50
    end

    test "the tick runs in a task and reports the remaining count", %{hub: hub} do
      assert {:noreply, state} = Coordinator.handle_info(:migration_retry_tick, hub)
      assert {:running, ref} = state.migration_retry_timer
      assert_receive {^ref, 0}
    end

    test "re-arms only while entries remain", %{hub: hub} do
      ref = make_ref()
      running = %{hub | migration_retry_timer: {:running, ref}}

      put_deferred(hub, [entry(:a)])
      assert {:noreply, state} = Coordinator.handle_info({ref, 1}, running)
      assert is_reference(state.migration_retry_timer)

      Storage.remove(hub.storage.misc, StorageKey.mdl())
      assert {:noreply, state} = Coordinator.handle_info({ref, 0}, running)
      assert state.migration_retry_timer == nil
    end

    test "a crashed tick reschedules instead of wedging the timer", %{hub: hub} do
      put_deferred(hub, [entry(:a)])
      ref = make_ref()
      running = %{hub | migration_retry_timer: {:running, ref}}

      assert {:noreply, state} =
               Coordinator.handle_info({:DOWN, ref, :process, self(), :boom}, running)

      assert is_reference(state.migration_retry_timer)
    end

    test "a draining node skips the presence heartbeat", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hdi(), 60_000)
      Storage.insert(hub.storage.misc, StorageKey.drn(), %{waiter: self()})

      assert {:noreply, _state} = Coordinator.handle_info(:propagate, hub)

      Storage.remove(hub.storage.misc, StorageKey.drn())
      assert {:noreply, _state} = Coordinator.handle_info(:propagate, hub)
    end
  end

  describe "drain/2" do
    test "single-node cluster returns error without touching children", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node()])
      {:ok, pid} = ConsentServer.start_link(%{})
      register_child(hub, :c1, pid)

      assert Migration.drain(hub.hub_id) == {:error, :no_target_nodes}
      assert Process.alive?(pid)
      assert {_cspec, [{_, ^pid}], %{}} = Storage.get(hub.hub_id, :c1)
      assert Migration.deferred_list(hub) == []
    end

    test "partitioned hub returns error", %{hub: hub} do
      # No dist_sup registered in the system registry means partitioned.
      assert Migration.drain(hub, []) == {:error, :partitioned}
    end

    test "locked hub returns error", %{hub: hub} do
      Registry.register(hub.procs.system_registry, "dist_sup", nil)

      assert Migration.drain(%{hub | pending_work_count: 1}, []) == {:error, :locked}
    end

    test "an already-draining node returns error", %{hub: hub} do
      Registry.register(hub.procs.system_registry, "dist_sup", nil)
      Storage.insert(hub.storage.misc, StorageKey.drn(), %{waiter: self()})

      assert Migration.drain(hub, []) == {:error, :draining}
    end

    test "distribution removal stops assigning the draining node", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hr(), Ring.create_ring([node(), @remote_node]))

      HookManager.register_handler(hub.storage.hook, Hook.pre_node_leave(), %HookManager{
        id: :ch_leave,
        m: ConsistentHashing,
        f: :handle_node_leave,
        a: [hub, :_]
      })

      Migration.handle_drain_distribution_removal(hub, node())

      assert Cluster.nodes(hub.storage.misc, [:include_local]) == [@remote_node]

      ring = Storage.get(hub.storage.misc, StorageKey.hr())
      assert Ring.key_to_nodes(ring, :any_child, 1) == [@remote_node]
    end

    test "deadline forces remaining deferred children with warning, hook, and summary",
         %{hub: hub} do
      Registry.register(hub.procs.system_registry, "dist_sup", nil)
      Storage.insert(hub.storage.misc, StorageKey.hr(), Ring.create_ring([node(), @remote_node]))

      HookManager.register_handler(hub.storage.hook, Hook.pre_node_leave(), %HookManager{
        id: :ch_leave,
        m: ConsistentHashing,
        f: :handle_node_leave,
        a: [hub, :_]
      })

      recv_hook(hub, Hook.drain_completed())

      {:ok, pid1} = ConsentServer.start_link(%{consent_reply: :defer})
      {:ok, pid2} = ConsentServer.start_link(%{consent_reply: :defer})
      register_child(hub, :c1, pid1)
      register_child(hub, :c2, pid2)

      log =
        capture_log(fn ->
          assert {:ok, %{migrated: 0, forced: 2}} = Migration.drain(hub, timeout: 300)
        end)

      assert log =~ "Force-migrating deferred children"
      assert_receive %{migrated: 0, forced: 2}
      assert Migration.deferred_list(hub) == []
      # A drained node must never rejoin the distribution on its own.
      assert Migration.draining?(hub)

      # Forced migration went through the best-effort handover path.
      assert {%{}, ^pid1} = Storage.get(hub.storage.misc, {:hotswap_state, :c1})
      assert {%{}, ^pid2} = Storage.get(hub.storage.misc, {:hotswap_state, :c2})

      # The local node is gone from the distribution.
      assert Cluster.nodes(hub.storage.misc, [:include_local]) == [@remote_node]
    end
  end
end
