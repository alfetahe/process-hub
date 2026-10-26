defmodule Test.ProcessHubNodedownGraceMultiNodeTest do
  @moduledoc """
  A node whose connection is lost keeps its children placed for the hub's
  `:nodedown_grace_period`: back within it, nothing moved; past it, the
  children move as without a grace; restarted within it on a hub without
  `:auto_recovery`, every child runs once again; a drained node's children move
  at once whatever the grace; a grace of 0 behaves as before.

  The hubs run on the peers only. The test node stays connected to every peer
  and watches; each child reports every start to the test process, so a child
  that starts and is stopped again at once is still seen. A survivor holding
  the lost node in its grace timers is the evidence that the loss was seen and
  deferred, so no assertion rests on a sleep.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Storage
  alias ProcessHub.Utility.Bag
  alias Test.Helper.{Bootstrap, Common, TestNode}

  @moduletag :multinode
  @moduletag timeout: 180_000

  @grace 2_500

  setup_all do
    peers =
      TestNode.start_nodes(3,
        prefix: "grace_mn",
        args: [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
      )

    Enum.each(peers, fn {_name, pid} -> :erlang.unlink(pid) end)
    on_exit(fn -> Bootstrap.kill_peers(peers) end)

    %{peers: Enum.map(peers, fn {name, _pid} -> name end)}
  end

  setup %{peers: peers} do
    on_exit(fn -> TestNode.heal(peers, peers) end)
    :ok
  end

  test "the grace is a hub setting, 0 unless set", %{peers: [node | _]} do
    for {settings, grace} <- [{[nodedown_grace_period: 1_234], 1_234}, {[], 0}] do
      hub_id = :"grace_setting_#{System.unique_integer([:positive])}"
      spec = struct(%ProcessHub{hub_id: hub_id}, settings)
      :erpc.call(node, Bootstrap, :start_hub_on_node, [spec, %{}])
      assert stored_grace(node, hub_id) == grace
      stop_hub([node], hub_id)
    end
  end

  test "a cut node back within the grace: nothing moved, nothing started twice",
       %{peers: peers} do
    hub_id = start_hub(peers, @grace)
    children = start_children(hub_id, peers, 30)
    cut = List.last(peers)
    survivors = peers -- [cut]
    held = local_running(cut, hub(cut, hub_id))
    assert held != [], "the cut node holds no child; raise the child count"

    TestNode.split([cut], survivors)

    assert_held(survivors, hub_id, cut)

    assert_kept_in_place(survivors, hub_id, peers, cut, held)

    TestNode.heal([cut], survivors)

    assert eventually(fn -> not Enum.any?(survivors, &holding?(&1, hub_id, cut)) end),
           "the rejoin never released the cut node's grace"

    assert_kept_in_place(survivors, hub_id, peers, cut, held)
    assert started_since_setup() == [], "children started after the split"
    assert redistributed_on() == [], "a node redistributed after the split"
    assert running_counts(hub_id, peers, children) == ones(children)
    assert Enum.sort(local_running(cut, hub(cut, hub_id))) == Enum.sort(held)

    stop_hub(peers, hub_id)
  end

  test "a cut node away past the grace: its children move, then run once after the heal",
       %{peers: peers} do
    hub_id = start_hub(peers, @grace)
    children = start_children(hub_id, peers, 30)
    cut = List.last(peers)
    survivors = peers -- [cut]
    held = local_running(cut, hub(cut, hub_id))

    split_at = now()
    TestNode.split([cut], survivors)

    assert_held(survivors, hub_id, cut)
    assert_kept_in_place(survivors, hub_id, peers, cut, held)

    assert eventually(
             fn -> running_counts(hub_id, survivors, children) == ones(children) end,
             @grace + 10_000
           ),
           "the survivors never took the cut node's children over"

    assert now() - split_at >= @grace, "the children moved before the grace ran out"
    assert moved_to(survivors) == Enum.sort(held)

    TestNode.heal([cut], survivors)

    assert eventually(
             fn -> running_counts(hub_id, peers, children) == ones(children) end,
             20_000
           )

    stop_hub(peers, hub_id)
  end

  test "a node that halts is replaced only after the grace", %{peers: peers} do
    [{doomed, doomed_pid}] = TestNode.start_nodes(1, prefix: "grace_mn_halt", args: [])
    :erlang.unlink(doomed_pid)
    nodes = peers ++ [doomed]

    hub_id = start_hub(nodes, @grace)
    children = start_children(hub_id, nodes, 30)
    held = local_running(doomed, hub(doomed, hub_id))
    assert held != [], "the halting node holds no child; raise the child count"

    halted_at = now()
    :erpc.cast(doomed, :erlang, :halt, [137])

    assert_held(peers, hub_id, doomed)

    assert_kept_in_place(peers, hub_id, nodes, doomed, held)

    assert eventually(
             fn -> running_counts(hub_id, peers, children) == ones(children) end,
             @grace + 10_000
           )

    assert now() - halted_at >= @grace, "the children moved before the grace ran out"
    assert moved_to(peers) == Enum.sort(held)

    stop_hub(peers, hub_id)
  end

  test "a node restarted within the grace without auto_recovery: every child runs once again",
       %{peers: peers} do
    [{restarted, first_pid}] = TestNode.start_nodes(1, prefix: "grace_mn_restart", args: [])
    :erlang.unlink(first_pid)
    nodes = peers ++ [restarted]

    # Far longer than the test waits, so whatever moves, the restart moved it.
    hub_id = start_hub(nodes, 120_000)
    children = start_children(hub_id, nodes, 30)
    assert local_running(restarted, hub(restarted, hub_id)) != []

    :erpc.cast(restarted, :erlang, :halt, [137])
    assert_held(peers, hub_id, restarted)

    [{^restarted, second_pid}] = TestNode.start_nodes(1, prefix: "grace_mn_restart", args: [])
    :erlang.unlink(second_pid)
    on_exit(fn -> Bootstrap.kill_peers([{restarted, second_pid}]) end)
    start_hub_on(restarted, hub_id, 120_000)

    assert eventually(
             fn -> running_counts(hub_id, nodes, children) == ones(children) end,
             30_000
           ),
           "not every child runs once: #{inspect(running_counts(hub_id, nodes, children))}"

    stop_hub(nodes, hub_id)
  end

  test "a drained node's children move at once whatever the grace", %{peers: peers} do
    hub_id = start_hub(peers, 30_000)
    children = start_children(hub_id, peers, 30)
    leaving = List.last(peers)
    staying = peers -- [leaving]

    {:ok, _} = drain(leaving, hub_id)
    stop_hub([leaving], hub_id)

    assert eventually(fn -> running_counts(hub_id, staying, children) == ones(children) end)
    refute Enum.any?(staying, &holding?(&1, hub_id, leaving))

    stop_hub(staying, hub_id)
  end

  test "a grace of 0 moves a cut node's children within one debounce, as before",
       %{peers: peers} do
    hub_id = start_hub(peers, 0)
    children = start_children(hub_id, peers, 30)
    cut = List.last(peers)
    survivors = peers -- [cut]
    held = local_running(cut, hub(cut, hub_id))

    TestNode.split([cut], survivors)

    assert eventually(fn -> running_counts(hub_id, survivors, children) == ones(children) end)
    refute Enum.any?(survivors, &holding?(&1, hub_id, cut))
    assert moved_to(survivors) == Enum.sort(held)

    TestNode.heal([cut], survivors)

    assert eventually(
             fn -> running_counts(hub_id, peers, children) == ones(children) end,
             20_000
           )

    stop_hub(peers, hub_id)
  end

  # The loss was seen and deferred; on failure, who still counts it a member.
  defp assert_held(observers, hub_id, lost) do
    assert eventually(fn -> Enum.all?(observers, &holding?(&1, hub_id, lost)) end),
           "a survivor never held #{lost} in its grace; memberships: " <>
             inspect(Map.new(observers, &{&1, membership(&1, hub_id)}))
  end

  # The lost node is still a member everywhere and its children's rows still
  # name it, so nothing can start them elsewhere.
  defp assert_kept_in_place(observers, hub_id, members, lost, held) do
    for node <- observers do
      assert membership(node, hub_id) == Enum.sort(members),
             "#{node} dropped #{lost} inside the grace"

      for child <- held do
        row = owner(node, hub_id, child)
        assert row == lost, "#{node} re-placed #{child} inside the grace: #{inspect(row)}"
      end
    end
  end

  defp start_hub(nodes, grace) do
    hub_id = :"grace_mn_#{System.unique_integer([:positive])}"
    Enum.each(nodes, &start_hub_on(&1, hub_id, grace))

    assert eventually(fn -> Enum.all?(nodes, &(membership(&1, hub_id) == Enum.sort(nodes))) end),
           "the hub never formed: #{inspect(Enum.map(nodes, &membership(&1, hub_id)))}"

    hub_id
  end

  defp start_hub_on(node, hub_id, grace) do
    spec = %ProcessHub{
      hub_id: hub_id,
      hubs_discover_interval: 300,
      cluster_event_debounce: 200,
      nodedown_grace_period: grace
    }

    hooks = %{
      Hook.pre_children_redistribution() => [
        %HookManager{
          id: :grace_watch,
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

  defp start_children(hub_id, [node | _] = nodes, count) do
    specs =
      for i <- 1..count do
        id = "#{hub_id}_c#{i}"
        %{id: id, start: {Test.Helper.TestServer, :start_link, [%{name: id, report_to: self()}]}}
      end

    {:ok, _} = :erpc.call(node, ProcessHub, :start_children, [hub_id, specs, []])
    ids = Enum.map(specs, & &1.id)

    assert eventually(fn ->
             running_counts(hub_id, nodes, ids) == ones(ids) and
               bound_everywhere?(hub_id, nodes, ids)
           end)

    # Drop the initial starts, so later reads see only what a fault caused.
    Bag.all_messages()
    ids
  end

  # Every node's registry binds every child to exactly one node.
  defp bound_everywhere?(hub_id, nodes, ids) do
    Enum.all?(nodes, fn node ->
      rows = :erpc.call(node, ProcessRegistry, :dump, [hub_id])
      Enum.all?(ids, &match?({_spec, [_], _meta}, rows[&1]))
    end)
  end

  defp holding?(node, hub_id, lost) do
    Map.has_key?(:erpc.call(node, :sys, :get_state, [hub_id]).nodedown_grace_timers, lost)
  end

  defp stored_grace(node, hub_id) do
    :erpc.call(node, Storage, :get, [hub(node, hub_id).storage.misc, StorageKey.ndg()])
  end

  defp moved_to(nodes) do
    for({:child_started, child, node} <- Bag.all_messages(), node in nodes, do: child)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp started_since_setup do
    for {:child_started, child, node} <- drain_mailbox(), do: {child, node}
  end

  defp redistributed_on do
    for {{:redistributed_on, node}, %{event: :node_leave}} <- drain_mailbox(),
        uniq: true,
        do: node
  end

  # Non-destructive read: messages go back so a later read sees them too.
  defp drain_mailbox do
    messages = Bag.all_messages()
    Enum.each(messages, &send(self(), &1))
    messages
  end

  defp drain(node, hub_id, attempts \\ 50) do
    case :erpc.call(node, ProcessHub.Service.Migration, :drain, [hub_id, [timeout: 10_000]]) do
      {:error, :locked} when attempts > 0 ->
        Process.sleep(100)
        drain(node, hub_id, attempts - 1)

      result ->
        result
    end
  end

  defp owner(node, hub_id, child) do
    case :erpc.call(node, ProcessRegistry, :lookup, [hub_id, child]) do
      {_spec, [{owner, _pid}]} -> owner
      other -> other
    end
  end

  defp hub(node, hub_id), do: :erpc.call(node, ProcessHub.Hub, :get, [hub_id])

  defp running_counts(hub_id, nodes, children) do
    running =
      Enum.flat_map(nodes, fn node ->
        case hub(node, hub_id) do
          nil -> []
          hub -> local_running(node, hub)
        end
      end)
      |> Enum.frequencies()

    Map.new(children, &{&1, Map.get(running, &1, 0)})
  catch
    :exit, _ -> %{}
  end

  defp local_running(node, hub) do
    :erpc.call(node, Supervisor, :which_children, [hub.procs.dist_sup])
    |> Enum.flat_map(fn {id, pid, _, _} -> if is_pid(pid), do: [id], else: [] end)
  catch
    :exit, _ -> []
  end

  defp ones(children), do: Map.new(children, &{&1, 1})

  defp membership(node, hub_id) do
    Enum.sort(:erpc.call(node, ProcessHub, :nodes, [hub_id, [:include_local]]))
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp eventually(fun, timeout \\ 10_000), do: Common.eventually(fun, timeout)
end
