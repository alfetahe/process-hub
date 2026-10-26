defmodule Test.ProcessHubQuorumMultiNodeTest do
  @moduledoc """
  The quorum strategies on real peers: a split stops the smaller side before it
  takes over anything, a heal leaves every child running once, and a drained
  node shrinks the cluster instead of counting as lost.

  The hubs run on the peers only. The test node stays connected to every peer
  and watches; each child reports every start to the test process, so a child
  that starts and is stopped again at once is still seen.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.PartitionTolerance.{Divergence, DynamicQuorum, StaticQuorum}
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Utility.Bag
  alias Test.Helper.{Bootstrap, Common, TestNode}

  @moduletag :multinode
  @moduletag timeout: 180_000

  setup_all do
    peers =
      TestNode.start_nodes(5,
        prefix: "quorum_mn",
        args: [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
      )

    Enum.each(peers, fn {_name, pid} -> :erlang.unlink(pid) end)
    on_exit(fn -> Bootstrap.kill_peers(peers) end)

    %{peers: Enum.map(peers, fn {name, _pid} -> name end)}
  end

  setup %{peers: peers} do
    # Every test leaves the peers fully connected again.
    on_exit(fn -> TestNode.heal(peers, peers) end)
    :ok
  end

  for {name, strategy} <- [
        static: Macro.escape(%StaticQuorum{quorum_size: 3}),
        dynamic: Macro.escape(%DynamicQuorum{quorum_size: 51})
      ] do
    test "a 3|2 split under #{name}: the minority stops first, the heal runs each child once",
         %{peers: peers} do
      hub_id = start_hub(peers, unquote(strategy))
      children = start_children(hub_id, hd(peers), 30)

      {majority, minority} = Enum.split(peers, 3)
      TestNode.split(majority, minority)

      assert eventually(fn -> Enum.all?(minority, &partitioned?(&1, hub_id)) end),
             "the minority never stopped"

      assert eventually(fn -> Enum.all?(majority, &(membership(&1, hub_id) == majority)) end)
      refute Enum.any?(majority, &partitioned?(&1, hub_id))

      assert eventually(fn -> running_counts(hub_id, majority, children) == ones(children) end),
             "the majority does not run every child once: " <>
               inspect(running_counts(hub_id, majority, children))

      messages = Bag.all_messages()

      redistributed_on_minority =
        for {{:redistributed_on, node}, %{event: :node_leave}} <- messages,
            node in minority,
            uniq: true,
            do: node

      assert redistributed_on_minority == [],
             "the minority took over children of the nodes it lost"

      started_on_minority =
        for {:child_started, child, node} <- messages, node in minority, do: child

      assert started_on_minority == [],
             "the minority started #{length(started_on_minority)} children after the split"

      TestNode.heal(majority, minority)

      assert eventually(fn -> Enum.all?(peers, &(membership(&1, hub_id) == Enum.sort(peers))) end)
      assert eventually(fn -> not Enum.any?(peers, &partitioned?(&1, hub_id)) end)

      assert eventually(
               fn -> running_counts(hub_id, peers, children) == ones(children) end,
               20_000
             ),
             "after the heal a child runs other than once: " <>
               inspect(not_once(hub_id, peers, children))

      stop_hub(peers, hub_id)
    end
  end

  test "draining 5 down to 2 under dynamic never stops the cluster", %{peers: peers} do
    hub_id = start_hub(peers, %DynamicQuorum{quorum_size: 51, threshold_time: 60})
    children = start_children(hub_id, hd(peers), 20)
    {remaining, leaving} = Enum.split(peers, 2)
    last = List.last(leaving)

    # One node first; its children land on the nodes that stay.
    drain_away([last], hub_id, peers)

    assert eventually(fn ->
             running_counts(hub_id, peers -- [last], children) == ones(children)
           end)

    # Then two at the same moment, all within the dynamic window.
    drain_away(leaving -- [last], hub_id, peers)

    assert eventually(fn -> Enum.all?(remaining, &(membership(&1, hub_id) == remaining)) end)
    refute Enum.any?(remaining, &partitioned?(&1, hub_id))

    stop_hub(remaining, hub_id)
  end

  test "two nodes drained at the same moment leave every child running once on the rest",
       %{peers: peers} do
    hub_id = start_hub(peers, %Divergence{})
    children = start_children(hub_id, hd(peers), 30)
    {remaining, leaving} = Enum.split(peers, 3)

    drain_away(leaving, hub_id, peers)

    assert eventually(fn -> running_counts(hub_id, remaining, children) == ones(children) end),
           "after two concurrent drains a child runs other than once: " <>
             inspect(not_once(hub_id, remaining, children))

    stop_hub(remaining, hub_id)
  end

  test "a drained node is reported once, as a leave, and its disconnect not at all",
       %{peers: peers} do
    hub_id = start_hub(peers, %Test.Support.RecordingPartition{recorder: self()})
    leaving = List.last(peers)
    staying = peers -- [leaving]

    {:ok, _} = drain(leaving, hub_id)
    stop_hub([leaving], hub_id)
    TestNode.split([leaving], staying)

    assert eventually(fn -> Enum.all?(staying, &(membership(&1, hub_id) == staying)) end)
    Process.sleep(500)

    reports = for {:toggle_lock, from, ^leaving, kind} <- Bag.all_messages(), do: {from, kind}
    assert Enum.sort(reports) == Enum.map(staying, &{&1, :leave})

    stop_hub(staying, hub_id)
  end

  test "a hub that leaves partition mode restarts only the held children nobody runs",
       %{peers: peers} do
    [a, b] = Enum.take(peers, 2)
    hub_id = start_hub([a, b], %Divergence{})
    children = start_children(hub_id, a, 10)
    [taken | _] = local_running(a, :erpc.call(a, ProcessHub.Hub, :get, [hub_id]))
    hub_b = :erpc.call(b, ProcessHub.Hub, :get, [hub_id])
    [own | _] = local_running(b, hub_b)

    # b claims a child a runs, as a node does for its own children once the
    # other side has taken them over, and then stops.
    spec = Enum.find(child_specs(hub_id, 10), &(&1.id == taken))
    stale = :erpc.call(b, :erlang, :whereis, [:init])
    :ok = :erpc.call(b, ProcessHub.Service.ProcessRegistry, :insert, [hub_id, spec, [{b, stale}]])
    :ok = :erpc.call(b, ProcessHub.Service.State, :toggle_quorum_failure, [hub_b])
    Bag.all_messages()

    :ok = :erpc.call(b, ProcessHub.Service.State, :toggle_quorum_success, [hub_b])

    assert_receive {:child_started, ^own, ^b}, 2_000
    refute_receive {:child_started, ^taken, ^b}, 1_000
    assert running_counts(hub_id, [a, b], children) == ones(children)

    stop_hub([a, b], hub_id)
  end

  test "two hubs that both lost their quorum both restart what they held", %{peers: peers} do
    [a, b] = Enum.take(peers, 2)
    hub_id = start_hub([a, b], %Divergence{})
    children = start_children(hub_id, a, 10)
    hubs = for n <- [a, b], do: {n, :erpc.call(n, ProcessHub.Hub, :get, [hub_id])}

    for {n, hub} <- hubs,
        do: :ok = :erpc.call(n, ProcessHub.Service.State, :toggle_quorum_failure, [hub])

    assert running_counts(hub_id, [a, b], children) |> Map.values() |> Enum.all?(&(&1 == 0))

    # a comes back first, beside b still stopped; then b, beside a running.
    for {n, hub} <- hubs,
        do: :ok = :erpc.call(n, ProcessHub.Service.State, :toggle_quorum_success, [hub])

    assert eventually(fn -> running_counts(hub_id, [a, b], children) == ones(children) end)

    # Each restarted child is bound again in the registry, to the node it runs on.
    for child <- children, n <- [a, b] do
      {_spec, node_pids} =
        :erpc.call(n, ProcessHub.Service.ProcessRegistry, :lookup, [hub_id, child])

      assert [{owner, pid}] = node_pids
      assert child in local_running(owner, :erpc.call(owner, ProcessHub.Hub, :get, [hub_id]))
      assert is_pid(pid)
    end

    stop_hub([a, b], hub_id)
  end

  test "a stop waiting on a node that is cut off answers at once", %{peers: peers} do
    [a, b] = Enum.take(peers, 2)
    hub_id = start_hub([a, b], %Divergence{})

    specs =
      for i <- 1..10 do
        id = "#{hub_id}_slow#{i}"
        args = %{name: id, report_to: self(), slow_stop_ms: 4_000}
        %{id: id, start: {Test.Helper.TestServer, :start_link, [args]}}
      end

    {:ok, _} = :erpc.call(a, ProcessHub, :start_children, [hub_id, specs, []])
    ids = Enum.map(specs, & &1.id)
    assert eventually(fn -> running_counts(hub_id, [a, b], ids) == ones(ids) end)
    [on_b | _] = local_running(b, :erpc.call(b, ProcessHub.Hub, :get, [hub_id]))

    stop =
      Task.async(fn ->
        :erpc.call(a, ProcessHub, :stop_children, [
          hub_id,
          [on_b],
          [awaitable: true, timeout: 20_000]
        ])
        |> then(&:erpc.call(a, ProcessHub, :await, [&1], 30_000))
      end)

    Process.sleep(500)
    started = System.monotonic_time(:millisecond)
    TestNode.split([b], [a])

    result = Task.await(stop, 30_000)

    assert System.monotonic_time(:millisecond) - started < 10_000,
           "the stop waited out its timeout"

    assert result.errors == [{on_b, {:error, :no_response}}]

    stop_hub([a, b], hub_id)
  end

  defp start_hub(nodes, strategy) do
    hub_id = :"quorum_mn_#{System.unique_integer([:positive])}"
    Enum.each(nodes, &start_hub_on(&1, hub_id, strategy))

    assert eventually(fn -> Enum.all?(nodes, &(membership(&1, hub_id) == Enum.sort(nodes))) end),
           "the hub never formed: #{inspect(Enum.map(nodes, &membership(&1, hub_id)))}"

    assert eventually(fn -> not Enum.any?(nodes, &partitioned?(&1, hub_id)) end)
    hub_id
  end

  defp start_hub_on(node, hub_id, strategy) do
    spec = %ProcessHub{
      hub_id: hub_id,
      partition_tolerance_strategy: strategy,
      hubs_discover_interval: 300,
      # The disconnects of one split land in one batch, as they do with the
      # default debounce.
      cluster_event_debounce: 200
    }

    # Reports each redistribution the node begins after losing nodes.
    hooks = %{
      Hook.pre_children_redistribution() => [
        %HookManager{
          id: :quorum_watch,
          m: Bag,
          f: :hook_erlang_send,
          a: [:_, self(), {:redistributed_on, node}]
        }
      ]
    }

    :erpc.call(node, Bootstrap, :start_hub_on_node, [spec, hooks])
  end

  defp stop_hub(nodes, hub_id) do
    Enum.each(nodes, &:erpc.call(&1, ProcessHub.Initializer, :stop, [hub_id]))
  end

  defp child_specs(hub_id, count) do
    for i <- 1..count do
      id = "#{hub_id}_c#{i}"
      %{id: id, start: {Test.Helper.TestServer, :start_link, [%{name: id, report_to: self()}]}}
    end
  end

  defp start_children(hub_id, node, count) do
    specs = child_specs(hub_id, count)

    {:ok, _} = :erpc.call(node, ProcessHub, :start_children, [hub_id, specs, []])
    ids = Enum.map(specs, & &1.id)

    assert eventually(fn -> running_counts(hub_id, Node.list(), ids) == ones(ids) end)

    # A node learns of a child started elsewhere only once its registration
    # arrives; a split before that leaves the other side unaware of the child.
    hub_nodes = membership(node, hub_id)
    assert eventually(fn -> Enum.all?(hub_nodes, &registered_all?(&1, hub_id, ids)) end)
    Bag.all_messages()
    ids
  end

  defp registered_all?(node, hub_id, ids) do
    Enum.all?(ids, fn id ->
      match?(
        {_, [_]},
        :erpc.call(node, ProcessHub.Service.ProcessRegistry, :lookup, [hub_id, id])
      )
    end)
  end

  # Drains `group` at once, stops its hubs and cuts it off from the rest.
  defp drain_away(group, hub_id, peers) do
    group
    |> Task.async_stream(&drain(&1, hub_id), timeout: 30_000)
    |> Enum.each(fn {:ok, result} -> {:ok, _} = result end)

    stop_hub(group, hub_id)
    TestNode.split(group, peers -- group)
  end

  # A hub busy with a cluster event answers :locked; the drain is retried.
  defp drain(node, hub_id, attempts \\ 50) do
    case :erpc.call(node, ProcessHub.Service.Migration, :drain, [hub_id, [timeout: 10_000]]) do
      {:error, :locked} when attempts > 0 ->
        Process.sleep(100)
        drain(node, hub_id, attempts - 1)

      result ->
        result
    end
  end

  defp running_counts(hub_id, nodes, children) do
    running =
      Enum.flat_map(nodes, fn node ->
        case :erpc.call(node, ProcessHub.Hub, :get, [hub_id]) do
          nil -> []
          hub -> local_running(node, hub)
        end
      end)
      |> Enum.frequencies()

    Map.new(children, &{&1, Map.get(running, &1, 0)})
  end

  defp local_running(node, hub) do
    :erpc.call(node, Supervisor, :which_children, [hub.procs.dist_sup])
    |> Enum.flat_map(fn {id, pid, _, _} -> if is_pid(pid), do: [id], else: [] end)
  catch
    :exit, _ -> []
  end

  defp ones(children), do: Map.new(children, &{&1, 1})

  defp not_once(hub_id, nodes, children) do
    Enum.reject(running_counts(hub_id, nodes, children), &(elem(&1, 1) == 1))
  end

  defp membership(node, hub_id) do
    Enum.sort(:erpc.call(node, ProcessHub, :nodes, [hub_id, [:include_local]]))
  end

  defp partitioned?(node, hub_id), do: :erpc.call(node, ProcessHub, :is_partitioned?, [hub_id])

  defp eventually(fun, timeout \\ 10_000), do: Common.eventually(fun, timeout)
end
