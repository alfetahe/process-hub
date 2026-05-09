defmodule Test.ProcessHub.Service.Storage.EtsTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Service.Storage.Ets, as: Backend

  setup do
    hub_id = :"ets_backend_test_#{System.unique_integer([:positive])}"
    {:ok, ref} = Backend.open(hub_id, [])
    on_exit(fn -> Backend.close(ref) end)
    {:ok, %{ref: ref}}
  end

  test "open is idempotent for the same hub_id", %{ref: ref} do
    assert {:ok, ^ref} = Backend.open(ref, [])
  end

  test "insert/3 + get/2 round-trip", %{ref: ref} do
    assert :ok = Backend.insert(ref, :k, :v)
    assert Backend.get(ref, :k) === :v
    assert Backend.get(ref, :missing) === nil
  end

  test "exists?/2 reflects insert and remove", %{ref: ref} do
    refute Backend.exists?(ref, :k)
    Backend.insert(ref, :k, :v)
    assert Backend.exists?(ref, :k)
    Backend.remove(ref, :k)
    refute Backend.exists?(ref, :k)
  end

  test "insert/4 with ttl stores 3-tuple", %{ref: ref} do
    Backend.insert(ref, :ttl_key, :ttl_value, ttl: 60_000)
    assert Backend.get(ref, :ttl_key) === :ttl_value
    [entry] = :ets.lookup(ref, :ttl_key)
    assert tuple_size(entry) === 3
  end

  test "insert/4 without ttl stores 2-tuple", %{ref: ref} do
    Backend.insert(ref, :no_ttl, :v, [])
    [entry] = :ets.lookup(ref, :no_ttl)
    assert tuple_size(entry) === 2
  end

  test "match/2 returns list of tuples", %{ref: ref} do
    Backend.insert(ref, :a, {:val_a, %{tag: "x"}})
    Backend.insert(ref, :b, {:val_b, %{tag: "x"}})
    Backend.insert(ref, :c, {:val_c, %{tag: "y"}})

    matches = Backend.match(ref, {:"$1", {:"$2", %{tag: "x"}}})
    assert length(matches) === 2
    assert Enum.all?(matches, &is_tuple/1)
    assert Enum.sort(matches) === [{:a, :val_a}, {:b, :val_b}]
  end

  test "export_all/1 returns all entries", %{ref: ref} do
    Backend.insert(ref, :x, 1)
    Backend.insert(ref, :y, 2)
    entries = Backend.export_all(ref)
    assert length(entries) === 2
    assert {:x, 1} in entries
    assert {:y, 2} in entries
  end

  test "foldl/3 accumulates over entries", %{ref: ref} do
    Backend.insert(ref, :a, 10)
    Backend.insert(ref, :b, 20)
    Backend.insert(ref, :c, 30)
    sum = Backend.foldl(ref, 0, fn {_k, v}, acc -> acc + v end)
    assert sum === 60
  end

  test "clear_all/1 empties the storage", %{ref: ref} do
    Backend.insert(ref, :a, 1)
    Backend.insert(ref, :b, 2)
    assert :ok = Backend.clear_all(ref)
    assert Backend.export_all(ref) === []
  end

  test "remove/2 returns :ok and removes the entry", %{ref: ref} do
    Backend.insert(ref, :gone, :v)
    assert :ok = Backend.remove(ref, :gone)
    refute Backend.exists?(ref, :gone)
  end

  test "close/1 deletes the table", %{ref: ref} do
    assert :ok = Backend.close(ref)
    assert :ets.info(ref) === :undefined
  end
end
