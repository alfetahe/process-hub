defmodule Test.CoordinatorStuckConnectionMultinodeTest do
  @moduledoc """
  A connection to a peer that stops reading (a network partition before the
  tick timeout notices it) must not crash the coordinator, and a coordinator
  restarted inside the hub must say so through a hook and keep its place on
  the peers however long the restart takes, while a hub stopped on a peer must
  leave the others even when its announcement never goes out.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.ProcessRegistry
  alias Test.Helper.Bootstrap
  alias Test.Helper.Common
  alias Test.Helper.TestNode

  @moduletag :multinode

  setup_all do
    peers = TestNode.start_nodes(2, prefix: "stuck_mn")

    for {_node, pid} <- peers do
      :erlang.unlink(pid)
      on_exit(fn -> if Process.alive?(pid), do: :peer.stop(pid) end)
    end

    [frozen, joining] = Enum.map(peers, &elem(&1, 0))
    {:ok, %{frozen: frozen, joining: joining}}
  end

  defp recording_hooks(test_pid) do
    Map.new([Hook.coordinator_shutdown(), Hook.coordinator_restarted()], fn key ->
      {key, [%HookManager{id: :"rec_#{key}", m: Kernel, f: :send, a: [test_pid, {:hook, key}]}]}
    end)
  end

  defp drain_hooks(acc \\ []) do
    receive do
      {:hook, key} -> drain_hooks([key | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.frequencies()
    end
  end

  defp start_hub_everywhere(conf, hooks, peers) do
    Bootstrap.start_hub_on_node(conf, hooks)
    for peer <- peers, do: :erpc.call(peer, Bootstrap, :start_hub_on_node, [conf, %{}])
    on_exit(fn -> stop_hub_everywhere(conf.hub_id, peers) end)
  end

  defp stop_hub_everywhere(hub_id, peers) do
    ProcessHub.Initializer.stop(hub_id)

    for peer <- peers do
      try do
        :erpc.call(peer, ProcessHub.Initializer, :stop, [hub_id])
      catch
        _, _ -> :ok
      end
    end
  end

  defp responsive?(pid) do
    :sys.get_state(pid, 2_000)
    true
  catch
    :exit, _ -> false
  end

  defp start_children(hub_id, count) do
    ids = for i <- 1..count, do: :"child_#{i}"
    specs = for id <- ids, do: %{id: id, start: {Agent, :start_link, [Kernel, :node, []]}}

    {:ok, _} =
      ProcessHub.start_children(hub_id, specs, awaitable: true)
      |> ProcessHub.Future.await()
      |> ProcessHub.StartResult.format()

    ids
  end

  defp local_ids(hub_id, ids),
    do:
      Enum.filter(
        ids,
        &ProcessHub.DistributedSupervisor.running_pid(ProcessHub.Hub.get(hub_id), &1)
      )

  defp hub_nodes(hub_id), do: Cluster.nodes(ProcessHub.Hub.get(hub_id).storage.misc)

  test "a peer that stops reading crashes no coordinator, on a heartbeat or a join",
       %{frozen: frozen, joining: joining} do
    hub_id = :"stuck_#{System.unique_integer([:positive])}"
    conf = %ProcessHub{hub_id: hub_id, hubs_discover_interval: 1_000, cluster_event_debounce: 0}

    start_hub_everywhere(conf, recording_hooks(self()), [frozen])
    assert Common.eventually(fn -> hub_nodes(hub_id) == [frozen] end)

    # A node with no local child sends a joining node no registry at all.
    assert local_ids(hub_id, start_children(hub_id, 8)) != []

    coordinator = Process.whereis(hub_id)
    event_queue = Process.whereis(:"hub.#{hub_id}.event_queue")
    drain_hooks()

    # Freeze the peer's OS process: its socket stops being read, as across a
    # partition, and the connection stays up until the tick timeout (45-75 s).
    os_pid = :erpc.call(frozen, :os, :getpid, [])
    {_, 0} = System.cmd("kill", ["-STOP", to_string(os_pid)])

    try do
      # Fill the connection past the busy limit; this process blocks, not the test.
      blob = :binary.copy(<<0>>, 1_048_576)
      spawn(fn -> for _ <- 1..256, do: send({:no_such_name, frozen}, blob) end)

      # The event queue itself is stuck sending to the peer: the condition the
      # coordinator must outlive.
      assert Common.eventually(
               fn -> Process.info(event_queue, :status) == {:status, :suspended} end,
               10_000
             )

      # A heartbeat dispatched into the stuck queue.
      send(coordinator, :propagate)
      assert responsive?(coordinator)

      # A node joining meanwhile is sent this node's registry through the same
      # queue, as on a partition heal that reconnects one peer before another.
      :erpc.call(joining, Bootstrap, :start_hub_on_node, [conf, %{}])
      on_exit(fn -> stop_hub_everywhere(hub_id, [joining]) end)
      assert Common.eventually(fn -> joining in hub_nodes(hub_id) end, 8_000)
      assert responsive?(coordinator)

      assert Process.info(event_queue, :status) == {:status, :suspended}
      assert Process.whereis(hub_id) == coordinator
      assert drain_hooks() == %{}
    after
      System.cmd("kill", ["-CONT", to_string(os_pid)])
    end
  end

  test "a coordinator restarted by its hub fires the restarted hook and keeps its bindings on peers",
       %{joining: peer} do
    hub_id = :"restarted_#{System.unique_integer([:positive])}"
    test_pid = self()

    hooks = %{
      Hook.coordinator_restarted() => [
        %HookManager{id: :rec_restarted, m: Kernel, f: :send, a: [test_pid, :_]}
      ]
    }

    start_hub_everywhere(%ProcessHub{hub_id: hub_id}, hooks, [peer])
    assert Common.eventually(fn -> hub_nodes(hub_id) == [peer] end)

    first = Process.whereis(hub_id)
    # Returns only after the coordinator's post-init setup, where the hook fires.
    :sys.get_state(first)
    refute_received %{hub_id: ^hub_id}

    # Enough children that some run here: the peer's bindings of those are
    # what a new boot token would purge.
    ids = start_children(hub_id, 16)

    bound_here = fn ->
      for id <- ids,
          {_, [{n, _}]} <- [:erpc.call(peer, ProcessRegistry, :lookup, [hub_id, id])],
          n == node(),
          do: id
    end

    assert Common.eventually(fn -> length(bound_here.()) == length(local_ids(hub_id, ids)) end)
    kept = bound_here.()
    assert kept != []

    Process.exit(first, :kill)

    assert_receive %{hub_id: ^hub_id}, 5_000
    second = Process.whereis(hub_id)
    assert is_pid(second) and second != first
    refute_received %{hub_id: ^hub_id}

    # The boot announcement has left the event queue, and the peer's
    # coordinator has handled every message that arrived before this call.
    :sys.get_state(:"hub.#{hub_id}.event_queue")
    :erpc.call(peer, :sys, :get_state, [hub_id])

    assert bound_here.() == kept
  end

  test "a peer whose hub stops leaves the hub even when its announcement is lost",
       %{joining: peer} do
    {hub_id, ids, _kept} = form_hub("stopped", peer, cluster_event_debounce: 0)

    # The peer's event queue holds the leave announcement until the stop kills it.
    :ok = :erpc.call(peer, :sys, :suspend, [:"hub.#{hub_id}.event_queue"])
    :ok = :erpc.call(peer, ProcessHub.Initializer, :stop, [hub_id])

    assert_left(hub_id, ids, peer)
  end

  test "a peer whose coordinator is slow to restart stays in the hub with its bindings",
       %{joining: peer} do
    {hub_id, ids, kept} = form_hub("slow_restart", peer)

    with_restart_held(peer, hub_id, fn coordinator ->
      Process.exit(coordinator, :kill)
      assert_kept(hub_id, ids, peer, kept)
    end)

    assert_kept(hub_id, ids, peer, kept)
  end

  test "a peer whose coordinator crashes announces no leave", %{joining: peer} do
    {hub_id, ids, kept} = form_hub("crashed", peer)

    with_restart_held(peer, hub_id, fn coordinator ->
      :ok = GenServer.stop(coordinator, :boom)
      # A leave announced on the way down has left the peer's event queue.
      :erpc.call(peer, :sys, :get_state, [:"hub.#{hub_id}.event_queue"])
      assert_kept(hub_id, ids, peer, kept)
    end)
  end

  test "a peer whose hub stops while this coordinator restarts still leaves",
       %{joining: peer} do
    {hub_id, ids, _kept} = form_hub("watcher_restart", peer)
    initializer = :erpc.call(peer, ProcessHub.Hub, :get, [hub_id]).procs.initializer

    # The peer's coordinator leaves the group and is not restarted.
    :ok = :erpc.call(peer, :sys, :suspend, [initializer])
    Process.exit(:erpc.call(peer, Process, :whereis, [hub_id]), :kill)
    assert Common.eventually(fn -> not handler_on?(hub_id, peer) end)

    # This node's new coordinator never saw that leave.
    first = Process.whereis(hub_id)
    Process.exit(first, :kill)
    assert Common.eventually(fn -> Process.whereis(hub_id) not in [nil, first] end)
    :sys.get_state(hub_id)

    # Killing the suspended supervisor takes the peer's whole hub down.
    Process.exit(initializer, :kill)

    assert_left(hub_id, ids, peer)
  end

  test "a leave applied while the node runs the hub removes nothing", %{joining: peer} do
    {hub_id, ids, kept} = form_hub("late_leave", peer)
    assert Common.eventually(fn -> handler_on?(hub_id, peer) end)

    Cluster.handle_node_down(%{
      removed_nodes: [peer],
      hub: ProcessHub.Hub.get(hub_id),
      kind: :leave
    })

    assert hub_nodes(hub_id) == [peer]
    assert bound_to(hub_id, ids, peer) == kept
  end

  defp form_hub(prefix, peer, settings \\ []) do
    hub_id = :"#{prefix}_#{System.unique_integer([:positive])}"
    start_hub_everywhere(struct(%ProcessHub{hub_id: hub_id}, settings), %{}, [peer])
    assert Common.eventually(fn -> hub_nodes(hub_id) == [peer] end)

    ids = start_children(hub_id, 16)
    assert Common.eventually(fn -> bound_to(hub_id, ids, peer) != [] end)
    {hub_id, ids, bound_to(hub_id, ids, peer)}
  end

  # Runs `fun` on the peer's coordinator while its hub cannot restart it.
  defp with_restart_held(peer, hub_id, fun) do
    initializer = :erpc.call(peer, ProcessHub.Hub, :get, [hub_id]).procs.initializer
    :ok = :erpc.call(peer, :sys, :suspend, [initializer])

    try do
      fun.(:erpc.call(peer, Process, :whereis, [hub_id]))
    after
      :erpc.call(peer, :sys, :resume, [initializer])
    end
  end

  defp assert_kept(hub_id, ids, peer, kept) do
    registry = :"hub.#{hub_id}.system_registry"

    assert Common.eventually(fn ->
             {:monitors, monitors} = Process.info(Process.whereis(hub_id), :monitors)
             {:process, {registry, peer}} in monitors
           end)

    # A DOWN for that monitor is sent before this reply, so the coordinator
    # has handled it by the next call; a leave it batched is still pending.
    assert is_pid(:erpc.call(peer, Process, :whereis, [registry]))
    state = :sys.get_state(hub_id)

    assert peer not in state.event_batches.cluster_leave.nodes
    assert hub_nodes(hub_id) == [peer]
    assert bound_to(hub_id, ids, peer) == kept
  end

  defp assert_left(hub_id, ids, peer) do
    assert Common.eventually(fn -> hub_nodes(hub_id) == [] end),
           "the stopped peer is still a member: #{inspect(hub_nodes(hub_id))}"

    assert Common.eventually(fn -> bound_to(hub_id, ids, peer) == [] end),
           "rows still bound to the stopped peer: #{inspect(bound_to(hub_id, ids, peer))}"
  end

  defp bound_to(hub_id, ids, node) do
    for id <- ids,
        {_, node_pids} <- [ProcessRegistry.lookup(hub_id, id)],
        Keyword.has_key?(node_pids, node),
        do: id
  end

  defp handler_on?(hub_id, node) do
    {:ok, handlers} = :blockade.get_handlers(:"hub.#{hub_id}.event_queue", :cluster_join_event)
    Enum.any?(handlers, &(node(&1) == node))
  end
end
