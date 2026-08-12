defmodule Test.SynchronizerCspecMergeTest do
  @moduledoc """
  Replica merge: rows resolve by `(epoch, changed_by)` and are adopted verbatim;
  `node_pids` carries per-node observations that only their owner may change, and
  an absent child withdraws nothing but the reporting node's own entry.
  """
  use ExUnit.Case

  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.ProcessRegistry.Row
  alias ProcessHub.Service.Synchronizer
  alias Test.Helper.Common

  @hub_id :sync_cspec_merge_test

  setup_all do
    Test.Helper.SetupHelper.setup_base(%{}, @hub_id)
  end

  setup do
    on_exit(fn -> ProcessRegistry.clear_all(@hub_id) end)
    {:ok, hub: ProcessHub.Coordinator.get_hub(@hub_id)}
  end

  defp spec(id, payload),
    do: %{id: id, start: {TestModuleRelay, :start_link, [{:default, payload}]}}

  defp payload(cs), do: elem(cs.start, 2) |> hd()

  defp row(id), do: ProcessRegistry.lookup(@hub_id, id, with_metadata: true, include_empty: true)

  defp hub_meta(id) do
    {_cs, _nodes, meta} = row(id)
    Row.meta(meta)
  end

  # Builds the metadata a peer would broadcast for a row it authored.
  defp peer_meta(tag, epoch, changed_by) do
    %{
      tag: tag,
      __process_hub__: %{
        epoch: epoch,
        lifecycle: :running,
        changed_at: 0,
        changed_by: changed_by
      }
    }
  end

  describe "epoch resolution" do
    test "a higher remote epoch wins and is adopted verbatim", %{hub: hub} do
      id = :epoch_remote_wins
      ProcessRegistry.insert(@hub_id, spec(id, :local), [{node(), self()}], metadata: %{tag: "l"})
      assert %{epoch: 1} = hub_meta(id)

      peer = :a_peer@nohost
      peer_pid = spawn(fn -> :ok end)

      Synchronizer.append_data(hub, %{
        peer => [{spec(id, :remote), peer_pid, peer_meta("r", 7, peer)}]
      })

      {cs, nodes, meta} = row(id)
      assert payload(cs) == {:default, :remote}
      assert Common.caller_meta(meta) == %{tag: "r"}
      # Adopted, not authored: the epoch is the winner's, not local + 1.
      assert %{epoch: 7, changed_by: ^peer} = Row.meta(meta)
      assert Keyword.get(nodes, peer) == peer_pid
      assert Keyword.get(nodes, node()) == self()
    end

    test "a lower remote epoch loses; only its pid observation lands", %{hub: hub} do
      id = :epoch_local_wins
      ProcessRegistry.insert(@hub_id, spec(id, :local), [{node(), self()}], metadata: %{tag: "l"})
      ProcessRegistry.insert(@hub_id, spec(id, :local), [{node(), self()}], metadata: %{tag: "l"})
      assert %{epoch: 2} = hub_meta(id)

      peer = :a_peer@nohost
      peer_pid = spawn(fn -> :ok end)

      Synchronizer.append_data(hub, %{
        peer => [{spec(id, :stale), peer_pid, peer_meta("stale", 1, peer)}]
      })

      {cs, nodes, meta} = row(id)
      assert payload(cs) == {:default, :local}
      assert Common.caller_meta(meta) == %{tag: "l"}
      assert %{epoch: 2} = Row.meta(meta)
      assert Keyword.get(nodes, peer) == peer_pid
    end

    test "equal epochs resolve by the lower authoring node name", %{hub: hub} do
      id = :epoch_tie
      ProcessRegistry.insert(@hub_id, spec(id, :local), [{node(), self()}], metadata: %{tag: "l"})
      %{epoch: epoch, changed_by: local_node} = hub_meta(id)

      lower = :aaa@nohost
      higher = :zzz@nohost
      assert lower < local_node and local_node < higher

      # The higher-named peer loses the tie.
      Synchronizer.append_data(hub, %{
        higher => [{spec(id, :hi), spawn(fn -> :ok end), peer_meta("hi", epoch, higher)}]
      })

      assert %{changed_by: ^local_node} = hub_meta(id)

      # The lower-named peer wins it.
      Synchronizer.append_data(hub, %{
        lower => [{spec(id, :lo), spawn(fn -> :ok end), peer_meta("lo", epoch, lower)}]
      })

      assert %{changed_by: ^lower, epoch: ^epoch} = hub_meta(id)
      {cs, _nodes, _meta} = row(id)
      assert payload(cs) == {:default, :lo}
    end

    test "the merge is order- and repetition-independent", %{hub: hub} do
      id = :epoch_converge
      a = :aaa@nohost
      b = :bbb@nohost
      pid = spawn(fn -> :ok end)

      from_a = {spec(id, :a), pid, peer_meta("a", 4, a)}
      from_b = {spec(id, :b), pid, peer_meta("b", 7, b)}

      Synchronizer.append_data(hub, %{a => [from_a], b => [from_b]})
      forward = row(id)

      ProcessRegistry.clear_all(@hub_id)
      Synchronizer.append_data(hub, %{b => [from_b], a => [from_a]})
      Synchronizer.append_data(hub, %{a => [from_a]})
      Synchronizer.append_data(hub, %{b => [from_b]})

      assert row(id) == forward
      assert %{epoch: 7, changed_by: ^b} = hub_meta(id)
    end
  end

  describe "observations" do
    test "an unknown child from a peer is learned", %{hub: hub} do
      id = :placement_learn_new
      peer = :peer@nohost
      peer_pid = spawn(fn -> :ok end)
      Synchronizer.append_data(hub, %{peer => [{spec(id, :remote), peer_pid, %{tag: "remote"}}]})

      {cs, nodes, meta} = row(id)
      assert payload(cs) == {:default, :remote}
      assert Common.caller_meta(meta) == %{tag: "remote"}
      assert Keyword.get(nodes, peer) == peer_pid
    end

    test "a payload only affects the reporting node's own entry", %{hub: hub} do
      id = :observation_scope
      a = :aaa@nohost
      b = :bbb@nohost
      pid_a = spawn(fn -> :ok end)
      pid_b = spawn(fn -> :ok end)

      ProcessRegistry.insert(@hub_id, spec(id, :x), [{a, pid_a}, {b, pid_b}], metadata: %{})

      # A stops reporting the child; B never spoke this round.
      Synchronizer.detach_data(hub, %{a => []})

      {_cs, nodes, meta} = row(id)
      assert Keyword.keys(nodes) == [b]
      assert Keyword.get(nodes, b) == pid_b
      assert %{lifecycle: :running} = Row.meta(meta)
    end

    test "a row survives losing its last observation and stays a reconcile candidate",
         %{hub: hub} do
      id = :observation_last
      a = :aaa@nohost
      ProcessRegistry.insert(@hub_id, spec(id, :x), [{a, spawn(fn -> :ok end)}], metadata: %{})

      Synchronizer.detach_data(hub, %{a => []})

      assert ProcessRegistry.lookup(@hub_id, id) == nil
      assert ProcessRegistry.entry_exists?(@hub_id, id)
      assert {_cs, [], _meta} = row(id)
      assert %{lifecycle: :running} = hub_meta(id)
    end

    # Regression for the absence-driven delete that `detach_data/2` used to
    # perform: a peer reporting an empty registry wiped rows it never owned.
    test "an empty payload from a booting peer deletes nothing", %{hub: hub} do
      for id <- [:absence_a, :absence_b, :absence_c] do
        ProcessRegistry.insert(@hub_id, spec(id, :x), [{node(), self()}], metadata: %{})
      end

      before = ProcessRegistry.dump_all(@hub_id)
      assert map_size(before) == 3

      booting_peer = :booting@nohost
      Synchronizer.append_data(hub, %{booting_peer => []})
      Synchronizer.detach_data(hub, %{booting_peer => []})

      assert ProcessRegistry.dump_all(@hub_id) == before
    end
  end
end
