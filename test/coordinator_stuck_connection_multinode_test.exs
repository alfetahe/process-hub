defmodule Test.CoordinatorStuckConnectionMultinodeTest do
  @moduledoc """
  A connection to a peer that stops reading (a network partition before the
  tick timeout notices it) must not crash the coordinator, and a coordinator
  restarted inside the hub must say so through a hook and keep its place on
  the peers.
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
end
