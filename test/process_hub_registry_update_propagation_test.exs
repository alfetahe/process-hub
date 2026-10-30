defmodule Test.ProcessHubRegistryUpdatePropagationTest do
  @moduledoc """
  Registry `update/4` cross-node semantics: a plain update is node-local
  (node-down purging depends on that), while `propagate: true` re-applies
  the same update function on every hub node so durable child_spec edits
  (e.g. an embedded plugin manifest) survive a restart driven from any
  node's registry copy.
  """
  use ExUnit.Case, async: false

  import Test.Helper.Common

  alias Test.Helper.TestNode
  alias Test.Helper.Bootstrap
  alias Test.Helper.RegistryUpdateFns
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Storage

  @hub :reg_upd_prop_hub

  setup do
    [{peer, peer_pid}] = TestNode.start_nodes(1, prefix: "reg_upd_prop")
    :erlang.unlink(peer_pid)

    on_exit(fn ->
      swallow(fn -> ProcessHub.Initializer.stop(@hub) end)
      swallow(fn -> :erpc.call(peer, ProcessHub.Initializer, :stop, [@hub]) end)
      if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
    end)

    conf = %ProcessHub{hub_id: @hub, hubs_discover_interval: 200, cluster_event_debounce: 0}
    :erpc.call(peer, Bootstrap, :start_hub_on_node, [conf, %{}])
    {:ok, pid} = ProcessHub.Initializer.start_link(conf)
    :erlang.unlink(pid)

    assert eventually(fn ->
             length(ProcessHub.nodes(@hub, [:include_local])) == 2 and
               length(:erpc.call(peer, ProcessHub, :nodes, [@hub, [:include_local]])) == 2
           end),
           "hubs never clustered"

    %{peer: peer}
  end

  defp swallow(fun) do
    try do
      fun.()
    catch
      _, _ -> :ok
    end
  end

  defp marker(hub_node, child_id) do
    case :erpc.call(hub_node, ProcessRegistry, :lookup, [@hub, child_id]) do
      {child_spec, _node_pids} -> Map.get(child_spec, :marker)
      other -> {:unexpected, other}
    end
  end

  test "plain update is node-local; propagate: true reaches every hub node", %{peer: peer} do
    child_id = "relay_with_manifest"
    child_spec = %{id: child_id, start: {:m, :f, [%{opts: [plugins: []]}]}}

    ProcessRegistry.insert(@hub, child_spec, [{node(), self()}])
    :erpc.call(peer, ProcessRegistry, :insert, [@hub, child_spec, [{node(), self()}]])

    # Documents the node-local contract: the peer's copy stays stale.
    assert :ok = ProcessRegistry.update(@hub, child_id, RegistryUpdateFns.put_marker(:local_only))
    assert marker(node(), child_id) == :local_only
    assert marker(peer, child_id) == nil

    # With propagation every node's copy converges.
    assert :ok =
             ProcessRegistry.update(
               @hub,
               child_id,
               RegistryUpdateFns.put_marker(:everywhere),
               propagate: true
             )

    assert marker(node(), child_id) == :everywhere
    assert marker(peer, child_id) == :everywhere
  end

  # The peer rejects with "No child found" and converges through peer sync, so
  # the rejection is no warning.
  test "propagation is best-effort when a peer misses the row", %{peer: peer} do
    child_id = "local_only_row"
    child_spec = %{id: child_id, start: {:m, :f, []}}

    ProcessRegistry.insert(@hub, child_spec, [{node(), self()}])

    # Local update succeeds even though the peer rejects with "No child found".
    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        assert :ok =
                 ProcessRegistry.update(
                   @hub,
                   child_id,
                   RegistryUpdateFns.put_marker(:set),
                   propagate: true
                 )
      end)

    refute log =~ "update propagation"
    assert marker(node(), child_id) == :set
    assert :erpc.call(peer, ProcessRegistry, :lookup, [@hub, child_id]) == nil
  end

  # A peer whose hub is not running, one still starting, has nothing to update.
  test "a peer whose hub is not running is skipped without a warning", %{peer: peer} do
    child_id = "peer_hub_down"
    ProcessRegistry.insert(@hub, %{id: child_id, start: {:m, :f, []}}, [{node(), self()}])

    # The peer is listed again once its hub's leave is processed: the window
    # a peer restarting inside the node-down grace opens.
    :ok = :erpc.call(peer, ProcessHub.Initializer, :stop, [@hub])
    assert eventually(fn -> peer not in ProcessHub.nodes(@hub) end)
    misc = ProcessHub.Hub.get(@hub).storage.misc
    Storage.insert(misc, StorageKey.hn(), [peer | Storage.get(misc, StorageKey.hn())])
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: :warning) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert :ok =
                 ProcessRegistry.update(
                   @hub,
                   child_id,
                   RegistryUpdateFns.put_marker(:set),
                   propagate: true
                 )
      end)

    assert log =~ "[debug] ProcessRegistry update propagation failed on #{inspect(peer)}", log
    refute log =~ "[warning] ProcessRegistry update propagation"
    assert marker(node(), child_id) == :set
  end
end
