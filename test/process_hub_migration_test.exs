defmodule Test.ProcessHubMigrationTest do
  @moduledoc """
  Increment 4 — hub-to-hub process migration hazards, exercised with two hubs on
  one node plus leadership (the oracle is the single serializer regardless of the
  requesting node, so this covers the coordination code paths):

    * duplicate migration -> two copies (serialization / trigger dedup)
    * lost-updates window  -> state carried across (freeze before snapshot)
    * cross-registry atomicity -> process in exactly one hub afterward
    * crash / rollback     -> target start fails, process restored on source
  """
  use ExUnit.Case

  alias ProcessHub.Service.Leadership
  alias ProcessHub.Service.Oracle
  alias ProcessHub.Service.ProcessRegistry
  alias Test.Helper.Common
  alias Test.Helper.TestServer

  @hub_a :migr_hub_a
  @hub_b :migr_hub_b

  setup do
    Leadership.stop()
    start_hub(@hub_a)
    start_hub(@hub_b)

    on_exit(fn ->
      ProcessHub.Initializer.stop(@hub_a)
      ProcessHub.Initializer.stop(@hub_b)
      Leadership.stop()
    end)

    %{hub_a: @hub_a, hub_b: @hub_b}
  end

  defp start_hub(hub_id) do
    {:ok, pid} = ProcessHub.Initializer.start_link(%ProcessHub{hub_id: hub_id})
    :erlang.unlink(pid)
  end

  defp with_oracle() do
    assert ProcessHub.start_leadership() == :ok
    assert Common.eventually(fn -> Oracle.whereis() != :undefined end)
  end

  defp spec(id), do: %{id: id, start: {TestServer, :start_link, [%{name: id}]}}

  defp start_worker(hub_id, id, state) do
    hub_id |> ProcessHub.start_child(spec(id), awaitable: true) |> ProcessHub.Future.await()
    {_spec, [{_node, pid}]} = ProcessHub.child_lookup(hub_id, id)
    Enum.each(state, fn {k, v} -> GenServer.call(pid, {:set_value, k, v}) end)
    pid
  end

  defp value(hub_id, id, key) do
    {_spec, [{_node, pid}]} = ProcessHub.child_lookup(hub_id, id)
    GenServer.call(pid, {:get_value, key})
  end


  test "migrate_process returns {:error, :no_oracle} when leadership is not started" do
    refute ProcessHub.is_leader?()
    assert ProcessHub.migrate_process(@hub_a, @hub_b, "no_oracle") == {:error, :no_oracle}
  end

  test "migrates a process to the target hub carrying its state (exactly one hub after)" do
    with_oracle()
    start_worker(@hub_a, "w1", %{counter: 7})

    assert {:ok, info} = ProcessHub.migrate_process(@hub_a, @hub_b, "w1")
    assert info.to == @hub_b

    # Cross-registry atomicity: gone from A, present in B.
    assert ProcessHub.child_lookup(@hub_a, "w1") == nil
    assert ProcessHub.child_lookup(@hub_b, "w1") != nil

    # State was frozen, snapshotted and handed over.
    assert value(@hub_b, "w1", :counter) == 7
  end

  test "concurrent migration requests do not double-start the process" do
    with_oracle()
    start_worker(@hub_a, "w2", %{counter: 1})

    [r1, r2] =
      [
        Task.async(fn -> ProcessHub.migrate_process(@hub_a, @hub_b, "w2") end),
        Task.async(fn -> ProcessHub.migrate_process(@hub_a, @hub_b, "w2") end)
      ]
      |> Enum.map(&Task.await(&1, 15_000))

    # Both observers agree on the single outcome.
    assert match?({:ok, _}, r1)
    assert match?({:ok, _}, r2)

    # Exactly one live copy in the target hub, and none left in the source.
    assert length(ProcessHub.get_pids(@hub_b, "w2")) == 1
    assert ProcessHub.child_lookup(@hub_a, "w2") == nil
  end

  test "target start failure rolls back, restoring the process on the source" do
    with_oracle()
    start_worker(@hub_a, "w3", %{counter: 42})

    failing_target = %{id: "w3", start: {TestServer, :start_link_err, [%{name: "w3"}]}}

    assert {:rolled_back, _reason} =
             ProcessHub.migrate_process(@hub_a, @hub_b, "w3", target_spec: failing_target)

    # The process is not lost: restored on the source, absent from the target.
    assert ProcessHub.child_lookup(@hub_a, "w3") != nil
    assert ProcessHub.child_lookup(@hub_b, "w3") == nil

    # The snapshot state was restored on the source.
    assert value(@hub_a, "w3", :counter) == 42
  end

  test "migration of a replicated (multi-location) process is refused" do
    with_oracle()

    # Inject a synthetic replicated entry (two locations) into the source hub.
    ProcessRegistry.bulk_insert(@hub_a, %{
      "replicated" => {spec("replicated"), [{node(), self()}, {:"ghost@127.0.0.1", self()}], %{}}
    })

    assert ProcessHub.migrate_process(@hub_a, @hub_b, "replicated") ==
             {:error, :replicated_not_supported}
  end
end
