defmodule Test.ProcessHub.Service.Storage.BehaviourComplianceTest do
  @moduledoc """
  Runs the same operation suite against every backend module and
  asserts identical observable behaviour modulo TTL sweeper precision.
  """

  use ExUnit.Case, async: false

  alias ProcessHub.Service.Storage.Ets, as: EtsBackend
  alias ProcessHub.Service.Storage.Dets, as: DetsBackend

  describe "ProcessHub.Service.Storage.Ets" do
    setup do
      hub_id = :"compl_ets_#{System.unique_integer([:positive])}"
      {:ok, ref} = EtsBackend.open(hub_id, [])
      on_exit(fn -> EtsBackend.close(ref) end)
      {:ok, %{module: EtsBackend, ref: ref}}
    end

    test("compliance suite", ctx, do: run_compliance(ctx))
  end

  describe "ProcessHub.Service.Storage.Dets" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "compl_dets_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      hub_id = :"compl_dets_#{System.unique_integer([:positive])}"
      path = Path.join(tmp_dir, "registry.dets")
      {:ok, ref} = DetsBackend.open(hub_id, path: path)

      on_exit(fn ->
        DetsBackend.close(ref)
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{module: DetsBackend, ref: ref}}
    end

    test("compliance suite", ctx, do: run_compliance(ctx))
  end

  defp run_compliance(%{module: m, ref: ref}) do
    refute m.exists?(ref, :missing)
    assert m.get(ref, :missing) === nil

    assert :ok = m.insert(ref, :a, :va)
    assert :ok = m.insert(ref, :b, :vb)
    assert :ok = m.insert(ref, :c, {:vc, %{tag: "z"}})
    assert :ok = m.insert(ref, :d, :vd, [])

    assert m.get(ref, :a) === :va
    assert m.get(ref, :b) === :vb
    assert m.get(ref, :c) === {:vc, %{tag: "z"}}
    assert m.get(ref, :d) === :vd
    assert m.exists?(ref, :a)

    all = m.export_all(ref)
    keys = Enum.map(all, &elem(&1, 0))
    assert Enum.sort(keys) === [:a, :b, :c, :d]

    sum = m.foldl(ref, 0, fn _entry, acc -> acc + 1 end)
    assert sum === 4

    matches = m.match(ref, {:"$1", {:"$2", %{tag: "z"}}})
    assert Enum.all?(matches, &is_tuple/1)
    assert Enum.member?(matches, {:c, :vc})

    assert :ok = m.remove(ref, :a)
    refute m.exists?(ref, :a)

    assert :ok = m.clear_all(ref)
    assert m.export_all(ref) === []

    assert :ok = m.insert_many(ref, [{:m1, :v1, []}, {:m2, :v2, [ttl: 60_000]}])
    assert m.get(ref, :m1) === :v1
    assert m.get(ref, :m2) === :v2
    assert {:m2, :v2, _expire} = List.keyfind(m.export_all(ref), :m2, 0)
  end
end
