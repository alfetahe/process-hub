defmodule Test.JanitorReplaceMultiNodeTest do
  @moduledoc """
  The guards that keep the janitor's re-placement of an expired churn
  placeholder from starting a second copy: only the node the distribution
  strategy names first submits the start, a node that does not answer whether
  the child runs defers it, and a stop that lands while the nodes are asked
  wins.

  The hub runs on the test node and one peer, so the test node's janitor is
  driven directly and its log is captured. A peer is made silent by suspending
  its distributed supervisor, which the check asks; the test waits for the
  check's request in that supervisor's queue instead of sleeping.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Strategy.Migration.SwapMigration
  alias ProcessHub.Worker.Janitor
  alias Test.Helper.{Bootstrap, Common, TestNode}

  @moduletag :multinode
  @moduletag timeout: 60_000

  setup_all do
    [{peer, pid}] = TestNode.start_nodes(1, prefix: "janitor_mn")
    :erlang.unlink(pid)
    on_exit(fn -> Bootstrap.kill_peers([{peer, pid}]) end)
    %{peer: peer}
  end

  setup %{peer: peer} do
    # The janitor's notices sit below the suite's :warning level.
    level = Logger.level()
    Logger.configure(level: :notice)
    hub_id = :"janitor_mn_#{System.unique_integer([:positive])}"
    nodes = [node(), peer]
    Enum.each(nodes, &start_hub_on(&1, hub_id))

    assert Common.eventually(fn ->
             Enum.all?(nodes, &(membership(&1, hub_id) == Enum.sort(nodes)))
           end),
           "the hub never formed"

    on_exit(fn ->
      Logger.configure(level: level)
      Enum.each(nodes, &:erpc.call(&1, ProcessHub.Initializer, :stop, [hub_id]))
    end)

    %{hub_id: hub_id, nodes: nodes}
  end

  test "a node the strategy does not name first starts nothing and only counts the attempt",
       %{hub_id: hub_id, nodes: nodes, peer: peer} do
    cspec = placeholder_owned_by(hub_id, nodes, peer)

    log =
      capture_log(fn ->
        assert {1, _next_at} = Janitor.purge_pending_registry(hub_id)[cspec.id]
      end)

    refute log =~ "Re-placing churn placeholder"
    assert running_on(hub_id, nodes, cspec.id) == []
  end

  test "a node that does not answer defers the start and logs why",
       %{hub_id: hub_id, nodes: nodes, peer: peer} do
    cspec = placeholder_owned_by(hub_id, nodes, node())
    dist_sup = suspend_dist_sup(peer, hub_id)

    log =
      capture_log(fn ->
        assert {1, _next_at} = Janitor.purge_pending_registry(hub_id)[cspec.id]
      end)

    :erpc.call(peer, :sys, :resume, [dist_sup])
    assert running_on(hub_id, nodes, cspec.id) == []

    assert log =~
             "child_id: #{cspec.id}, module: Test.Helper.TestServer, " <>
               "attempt: 1 of 5, deferred, a node did not answer"
  end

  test "a stop that lands while the nodes are asked is not undone",
       %{hub_id: hub_id, nodes: nodes, peer: peer} do
    cspec = placeholder_owned_by(hub_id, nodes, node())
    dist_sup = suspend_dist_sup(peer, hub_id)

    test_pid = self()

    purge =
      Task.async(fn ->
        capture_log(fn -> send(test_pid, {:progress, Janitor.purge_pending_registry(hub_id)}) end)
      end)

    assert Common.eventually(fn ->
             :erpc.call(peer, Process, :info, [dist_sup, :message_queue_len]) ==
               {:message_queue_len, 1}
           end),
           "the check never asked the peer"

    {:ok, future} = ProcessHub.stop_child(hub_id, cspec.id, awaitable: true, timeout: 2_000)
    ProcessHub.Future.await(future)
    assert ProcessRegistry.lookup(hub_id, cspec.id, include_empty: true) == nil

    :erpc.call(peer, :sys, :resume, [dist_sup])
    log = Task.await(purge, 10_000)

    assert_received {:progress, %{} = progress}
    assert {1, _next_at} = progress[cspec.id]
    refute log =~ "submitted"
    assert running_on(hub_id, nodes, cspec.id) == []
    assert ProcessHub.get_pid(hub_id, cspec.id) == nil
  end

  # An expired placeholder on every node for a child the strategy places on
  # `owner` first.
  defp placeholder_owned_by(hub_id, nodes, owner) do
    hub = ProcessHub.Hub.get(hub_id)

    id =
      1..100
      |> Enum.map(&"#{hub_id}_c#{&1}")
      |> Enum.find(fn id -> match?([^owner | _], SwapMigration.belongs_to(hub, [id])[id]) end)

    cspec = %{id: id, start: {Test.Helper.TestServer, :start_link, [%{name: id}]}}

    Enum.each(nodes, fn node ->
      :erpc.call(node, ProcessRegistry, :insert, [hub_id, cspec, [], [metadata: %{}, ttl: -1000]])
    end)

    cspec
  end

  defp suspend_dist_sup(node, hub_id) do
    hub = :erpc.call(node, ProcessHub.Hub, :get, [hub_id])
    pid = :erpc.call(node, GenServer, :whereis, [hub.procs.dist_sup])
    :ok = :erpc.call(node, :sys, :suspend, [pid])
    pid
  end

  defp running_on(hub_id, nodes, child_id) do
    for node <- nodes,
        hub = :erpc.call(node, ProcessHub.Hub, :get, [hub_id]),
        {^child_id, pid, _, _} <-
          :erpc.call(node, Supervisor, :which_children, [hub.procs.dist_sup]),
        is_pid(pid),
        do: node
  end

  defp start_hub_on(node, hub_id) do
    spec = %ProcessHub{
      hub_id: hub_id,
      hubs_discover_interval: 300,
      cluster_event_debounce: 200,
      # The test drives the janitor; its own sweep must not run meanwhile.
      storage_purge_interval: 600_000
    }

    :erpc.call(node, Bootstrap, :start_hub_on_node, [spec, %{}])
  end

  defp membership(node, hub_id) do
    Enum.sort(:erpc.call(node, ProcessHub, :nodes, [hub_id, [:include_local]]))
  end
end
