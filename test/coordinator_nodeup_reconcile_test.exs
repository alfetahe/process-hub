defmodule Test.CoordinatorNodeupReconcileTest do
  @moduledoc """
  Unit coverage for the node-up membership reconciliation fail-safe: option
  wiring, per-node timer scheduling/cancellation, and the same-hub guard.

  Single-node, no peers. Assertions exploit the coordinator's FIFO mailbox: a
  synchronous `get_hub/1` issued after a `send/2` observes the message already
  handled, so no polling/sleeps are needed. The positive cross-node merge needs
  a real peer (a same-hub node only appears in the pg handler set when another
  node registers it) and is left to the multinode suite.
  """
  use ExUnit.Case, async: false

  alias ProcessHub.Coordinator
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey

  @fake :"fake@127.0.0.1"

  defp start_hub(opts) do
    id = :"nodeup_reconcile_#{System.unique_integer([:positive])}"
    {:ok, pid} = ProcessHub.Initializer.start_link(struct(%ProcessHub{hub_id: id}, opts))
    :erlang.unlink(pid)
    on_exit(fn -> if ProcessHub.is_alive?(id), do: ProcessHub.Initializer.stop(id) end)
    id
  end

  defp hub(id), do: Coordinator.get_hub(id)

  test "the configured interval is wired into misc storage; default is 3000" do
    assert Storage.get(
             hub(start_hub(nodeup_reconcile_interval: 1234)).storage.misc,
             StorageKey.nri()
           ) ===
             1234

    assert Storage.get(hub(start_hub([])).storage.misc, StorageKey.nri()) === 3000
  end

  test "interval 0 disables the fail-safe — :nodeup schedules no timer" do
    id = start_hub(nodeup_reconcile_interval: 0)

    send(id, {:nodeup, @fake})
    assert hub(id).nodeup_reconcile_timers === %{}
  end

  test ":nodeup schedules a per-node timer that :nodedown cancels" do
    id = start_hub(nodeup_reconcile_interval: 60_000)

    send(id, {:nodeup, @fake})
    assert Map.has_key?(hub(id).nodeup_reconcile_timers, @fake)

    send(id, {:nodedown, @fake})
    refute Map.has_key?(hub(id).nodeup_reconcile_timers, @fake)
  end

  test "the fail-safe never batches a node that is not a same-hub peer" do
    id = start_hub(nodeup_reconcile_interval: 60_000)

    # Fire the reconcile directly for a node absent from our pg handler set. The
    # 500ms debounce default has not elapsed when get_hub runs, so a broken
    # guard that batched unconditionally would leave @fake in the batch here.
    send(id, {:nodeup_reconcile, @fake})
    assert hub(id).event_batches.cluster_join.nodes === []
  end
end
