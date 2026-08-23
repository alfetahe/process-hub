defmodule Test.SynchronizerCspecMergeTest do
  @moduledoc """
  `append_data/2` reconciles process placement, not spec/metadata content. A
  peer replaying stale durable state must not overwrite a known child's local
  spec or metadata (only its pid mapping); an unknown child is still learned.
  """
  use ExUnit.Case

  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Synchronizer

  @hub_id :sync_cspec_merge_test

  setup_all do
    Test.Helper.SetupHelper.setup_base(%{}, @hub_id)
  end

  setup do
    on_exit(fn -> ProcessRegistry.clear_all(@hub_id) end)
    :ok
  end

  defp spec(id, payload),
    do: %{id: id, start: {TestModuleRelay, :start_link, [{:default, payload}]}}

  defp payload(cs), do: elem(cs.start, 2) |> hd()

  test "a peer's spec/metadata do not overwrite the local entry; only its pid is recorded" do
    id = :placement_keep_local

    ProcessRegistry.insert(@hub_id, spec(id, :local), [{node(), self()}],
      metadata: %{tag: "local"}
    )

    peer = :peer@nohost
    peer_pid = spawn(fn -> :ok end)
    hub = ProcessHub.Coordinator.get_hub(@hub_id)
    Synchronizer.append_data(hub, %{peer => [{spec(id, :stale), peer_pid, %{tag: "stale"}}]})

    {cs, nodes, meta} = ProcessRegistry.lookup(@hub_id, id, with_metadata: true)
    assert payload(cs) == {:default, :local}
    assert meta == %{tag: "local"}
    assert Keyword.get(nodes, peer) == peer_pid
  end

  test "an unknown child from a peer is learned" do
    id = :placement_learn_new
    peer = :peer@nohost
    peer_pid = spawn(fn -> :ok end)
    hub = ProcessHub.Coordinator.get_hub(@hub_id)
    Synchronizer.append_data(hub, %{peer => [{spec(id, :remote), peer_pid, %{tag: "remote"}}]})

    {cs, nodes, meta} = ProcessRegistry.lookup(@hub_id, id, with_metadata: true)
    assert payload(cs) == {:default, :remote}
    assert meta == %{tag: "remote"}
    assert Keyword.get(nodes, peer) == peer_pid
  end
end
