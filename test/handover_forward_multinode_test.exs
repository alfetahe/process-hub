defmodule Test.HandoverForwardMultiNodeTest do
  @moduledoc """
  Messages sent to a child's old process while it moves to a joining node
  reach the new process after the handed-over state, in order, none twice.

  A writer per child sends numbered messages to the child's old pid, the way a
  sender holding a stale pid would, while the peer joins and the distribution
  moves part of the children there.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Distribution.Base, as: Distribution
  alias ProcessHub.Strategy.Migration.{ColdSwap, HotSwap}
  alias Test.Helper.{Bootstrap, Common, TestNode}

  @moduletag :multinode
  @moduletag timeout: 60_000

  @children 20

  setup_all do
    [{peer, pid}] = TestNode.start_nodes(1, prefix: "handover_fwd_mn")
    :erlang.unlink(pid)
    on_exit(fn -> Bootstrap.kill_peers([{peer, pid}]) end)
    %{peer: peer}
  end

  # Each moved child's new process holds the messages from its handed-over
  # state, then the ones its old process received after that state was read:
  # those reach it only by being passed on. A message that reaches the old
  # process after its last mailbox read, as it exits, is lost like a message
  # to any process that stops, so only the end of what was sent may be missing.
  test "HotSwap passes the messages on after the state, in order", %{peer: peer} do
    for moved <- move(peer, %HotSwap{handover: true, forward_messages: true}),
        do: assert_passed_on(moved)
  end

  test "ColdSwap passes the kept messages on after the state, in order", %{peer: peer} do
    for moved <- move(peer, %ColdSwap{handover: true, forward_messages: true}),
        do: assert_passed_on(moved)
  end

  defp assert_passed_on({child_id, log, handed_over, sent}) do
    assert log == Enum.to_list(1..length(log)) and length(log) <= sent, explain(log, sent)
    assert length(log) > handed_over, "#{child_id}: nothing was passed on after the state"
  end

  # Returns `{child_id, log, handed_over, sent}` for each child that moved to `peer`.
  defp move(peer, strategy) do
    hub_id = :"handover_fwd_#{System.unique_integer([:positive])}"
    start_hub_on(node(), hub_id, strategy)
    on_exit(fn -> Enum.each([node(), peer], &stop_hub_on(&1, hub_id)) end)

    ids = Enum.map(1..@children, &"#{hub_id}_#{&1}")
    specs = Enum.map(ids, &%{id: &1, start: {Test.Helper.TestServer, :start_link, [%{name: &1}]}})
    {:ok, future} = ProcessHub.start_children(hub_id, specs, awaitable: true, timeout: 10_000)
    ProcessHub.Future.await(future)

    test_pid = self()
    olds = Map.new(ids, &{&1, ProcessHub.get_pid(hub_id, &1)})
    writers = Map.new(olds, fn {id, old} -> {id, spawn_writer(hub_id, id, old, test_pid)} end)

    start_hub_on(peer, hub_id, strategy)

    assert Common.eventually(fn ->
             Enum.sort(ProcessHub.nodes(hub_id, [:include_local])) == Enum.sort([node(), peer])
           end),
           "the hub never formed"

    hub = ProcessHub.Hub.get(hub_id)

    moved =
      for {id, [^peer | _]} <- Distribution.belongs_to(hub_strategy(hub), hub, ids, 1), do: id

    assert moved != [], "no child belongs to the peer"

    assert Common.eventually(fn -> all_on?(hub_id, moved, peer) end, 15_000),
           "the children never moved"

    Enum.each(writers, fn {_id, writer} -> send(writer, :stop) end)

    sent =
      Map.new(ids, fn id ->
        assert_receive({:sent, ^id, n}, 5_000)
        {id, n}
      end)

    for id <- moved do
      pid = ProcessHub.get_pid(hub_id, id)
      handed_over = handed_over(pid)
      # The old process's DOWN reaches the new one after all it passed on, and
      # ColdSwap's kept messages follow the state from the same sender. The
      # new process re-sends each batch to itself, so one more call lets the
      # re-sent messages land before the log is read.
      :ok = GenServer.call(pid, {:await_down, olds[id]})
      :pong = GenServer.call(pid, :ping)
      {id, log(pid), handed_over, sent[id]}
    end
  end

  defp handed_over(pid) do
    assert Common.eventually(fn -> GenServer.call(pid, {:get_value, :handed_over_log}) end),
           "the state never reached the new process"

    GenServer.call(pid, {:get_value, :handed_over_log})
  end

  # Sends 1, 2, 3, ... to the child's first pid until that pid is no longer
  # the registered one or is gone, or until told to stop; reports how many.
  defp spawn_writer(hub_id, child_id, old, test_pid) do
    spawn_link(fn -> write(hub_id, child_id, old, 1, test_pid) end)
  end

  defp write(hub_id, child_id, old, n, test_pid) do
    receive do
      :stop -> send(test_pid, {:sent, child_id, n - 1})
    after
      0 ->
        cond do
          not Process.alive?(old) or ProcessHub.get_pid(hub_id, child_id) not in [old, nil] ->
            receive do: (:stop -> send(test_pid, {:sent, child_id, n - 1}))

          # An unbounded flood outruns what the old process can pass on over
          # the network, and its stop then waits behind the backlog.
          match?({_, len} when len > 100, Process.info(old, :message_queue_len)) ->
            write(hub_id, child_id, old, n, test_pid)

          true ->
            send(old, {:append, n})
            write(hub_id, child_id, old, n + 1, test_pid)
        end
    end
  end

  defp explain(log, sent) do
    missing = Enum.to_list(1..sent) -- log
    twice = log -- Enum.uniq(log)

    "got #{length(log)} of #{sent}; missing #{inspect(Enum.take(missing, 10))}, " <>
      "twice #{inspect(Enum.take(twice, 10))}, out of order: #{log != Enum.sort(log)}"
  end

  defp log(pid), do: (GenServer.call(pid, {:get_value, :log}) || []) |> Enum.reverse()

  defp all_on?(hub_id, ids, node) do
    Enum.all?(ids, fn id ->
      match?({_, [{^node, _}]}, ProcessHub.child_lookup(hub_id, id))
    end)
  end

  defp hub_strategy(hub),
    do: ProcessHub.Service.Storage.get(hub.storage.misc, ProcessHub.Constant.StorageKey.strdist())

  defp start_hub_on(node, hub_id, strategy) do
    spec = %ProcessHub{
      hub_id: hub_id,
      hubs_discover_interval: 300,
      cluster_event_debounce: 200,
      migration_strategy: strategy
    }

    :erpc.call(node, Bootstrap, :start_hub_on_node, [spec, %{}])
  end

  defp stop_hub_on(node, hub_id) do
    :erpc.call(node, ProcessHub.Initializer, :stop, [hub_id])
  catch
    _, _ -> :ok
  end
end
