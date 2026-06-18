defmodule Test.ProcessHubSplitBrainMultiNodeTest do
  @moduledoc """
  Reproduction probe for the production split-brain: two BEAM-connected
  controllers whose hubs must converge into one membership, otherwise each
  stays a solo leader and relays are dropped on a rolling restart.

  The field order is "node A is up solo, node B boots ~16s later (past the 15s
  formation timeout), connects, and creates its hub" — so convergence hinges on
  the late-starting coordinator's `pg`-join being observed by the existing one
  (via `Blockade.monitor_handlers`) plus the 10s `:propagate` broadcast to
  `:external` members. Recovery gating is NOT on this path:
  `Recovery.gate_closed?/1` is only true at boot with a marker present, never on
  an already-`:normal` coordinator.

  This test drives exactly that order and asserts both nodes see the full
  membership. To watch the coordinator's formation logging in `coordinator.ex`
  (boot handler set, pg join/leave, propagate external set, batch flush, hub
  merge), temporarily bump the level to `:info` here while debugging.
  """

  use ExUnit.Case, async: false

  alias Test.Helper.TestNode
  alias Test.Helper.Bootstrap

  @moduletag :multinode

  setup_all do
    [{peer_name, peer_pid}] = TestNode.start_nodes(1, prefix: "split_brain_mn")
    :erlang.unlink(peer_pid)

    on_exit(fn ->
      if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
    end)

    {:ok, %{peer: peer_name}}
  end

  defp unique_id(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp membership(node, hub_id) when node === node() do
    Enum.sort(ProcessHub.nodes(hub_id, [:include_local]))
  end

  defp membership(node, hub_id) do
    Enum.sort(:erpc.call(node, ProcessHub, :nodes, [hub_id, [:include_local]]))
  end

  defp eventually(fun, timeout \\ 8_000), do: Test.Helper.Common.eventually(fun, timeout)

  test "a late-joining controller merges into the existing solo hub", %{peer: peer} do
    hub_id = unique_id(:split_brain)

    spec = %ProcessHub{
      hub_id: hub_id,
      # Short discover interval so :propagate fires several times within the
      # assertion window (prod default is 10s).
      hubs_discover_interval: 300,
      cluster_event_debounce: 0
    }

    # Node A: existing solo hub. The peer is connected but has no coordinator
    # yet, so it is not in the cluster_join pg group — local is genuinely solo.
    Bootstrap.start_hub_on_node(spec, %{})

    on_exit(fn ->
      ProcessHub.Initializer.stop(hub_id)
      :erpc.call(peer, ProcessHub.Initializer, :stop, [hub_id])
    end)

    assert eventually(fn -> membership(node(), hub_id) == [node()] end),
           "local hub did not start solo: #{inspect(membership(node(), hub_id))}"

    # Node B boots later and creates its hub on the already-connected peer.
    :erpc.call(peer, Bootstrap, :start_hub_on_node, [spec, %{}])

    both = Enum.sort([node(), peer])

    # THE ASSERTION UNDER TEST: the late join must converge both hubs to the
    # full membership. If pg does not surface B's coordinator to A and
    # :propagate resolves :external to an empty set, this never converges.
    assert eventually(fn -> membership(node(), hub_id) == both end, 10_000),
           "SPLIT-BRAIN: local never saw the late joiner; sees #{inspect(membership(node(), hub_id))}"

    assert eventually(fn -> membership(peer, hub_id) == both end, 10_000),
           "SPLIT-BRAIN: peer never merged the existing hub; sees #{inspect(membership(peer, hub_id))}"
  end
end
