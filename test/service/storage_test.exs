defmodule Test.Service.StorageTest do
  alias ProcessHub.Service.Storage

  use ExUnit.Case

  @hub_id :storage_test

  setup do
    Test.Helper.SetupHelper.setup_base(%{}, @hub_id)
  end

  test "exists", %{hub: %ProcessHub.Hub{storage: %{misc: misc_storage}}} do
    assert Storage.exists?(misc_storage, :test) === false

    Storage.insert(misc_storage, :test, :test_value)

    assert Storage.exists?(misc_storage, :test) === true
  end

  test "insert", %{hub: %ProcessHub.Hub{storage: %{misc: misc_storage}}} do
    assert Storage.get(misc_storage, :test) === nil

    Storage.insert(misc_storage, :test_insert, :test_value)
    Storage.insert(misc_storage, :test_insert2, :test_value2, ttl: 5000)

    assert Storage.get(misc_storage, :test_insert) === :test_value

    value = Storage.get(misc_storage, :test_insert2)

    assert value === :test_value2
  end

  test "get", %{hub: %ProcessHub.Hub{storage: %{misc: misc_storage}}} do
    assert Storage.get(misc_storage, :test) === nil

    Storage.insert(misc_storage, :test, :test_value)
    Storage.insert(misc_storage, :test2, :test_value2)

    assert Storage.get(misc_storage, :test) === :test_value
    assert Storage.get(misc_storage, :test2) === :test_value2
    assert Storage.get(misc_storage, :non_exist) === nil
  end

  test "match", %{hub: %ProcessHub.Hub{storage: %{misc: misc_storage}}} do
    match = {:"$1", {:"$2", %{some_key: "some_value"}}}

    assert Storage.match(misc_storage, match) === []

    Storage.insert(misc_storage, :test1, {:test_value1, %{some_key: "some_value"}})
    Storage.insert(misc_storage, :test2, {:test_value2, %{some_key: "some_value"}})
    Storage.insert(misc_storage, :test3, {:test_value3, %{other_key: "some_value"}})
    Storage.insert(misc_storage, :test4, :test_value4)

    assert Storage.match(misc_storage, match) === [
             {:test2, :test_value2},
             {:test1, :test_value1}
           ]

    assert Storage.match(misc_storage, {:"$1", :"$2", %{some_key: "no_existing"}}) === []
  end

  test "update", %{hub: %ProcessHub.Hub{storage: %{misc: misc_storage}}} do
    res1 = Storage.update(misc_storage, :not_exist_update1, fn val -> val end)
    res2 = Storage.update(misc_storage, :not_exist_update2, fn _val -> 5000 end)

    Storage.insert(misc_storage, :exist_update1, 4)
    res3 = Storage.update(misc_storage, :exist_update1, fn val -> val * 2 end)

    assert Storage.get(misc_storage, :not_exist_update1) === nil
    assert Storage.get(misc_storage, :not_exist_update2) === 5000
    assert Storage.get(misc_storage, :exist_update1) === 8

    assert res1 === true
    assert res2 === true
    assert res3 === true
  end

  test "remove", %{hub: %ProcessHub.Hub{storage: %{misc: misc_storage}}} do
    Storage.insert(misc_storage, :test_remove_1, "test_value_delete_1")
    Storage.insert(misc_storage, :test_remove_2, "test_value_delete_2")
    Storage.insert(misc_storage, "test_remove_3", "test_value_delete_3")
    Storage.insert(misc_storage, "test_remove_4", "test_value_delete_4")

    assert Storage.get(misc_storage, :test_remove_1) === "test_value_delete_1"
    assert Storage.get(misc_storage, :test_remove_2) === "test_value_delete_2"
    assert Storage.get(misc_storage, "test_remove_3") === "test_value_delete_3"
    assert Storage.get(misc_storage, "test_remove_4") === "test_value_delete_4"

    Storage.remove(misc_storage, :test_remove_1)
    Storage.remove(misc_storage, :test_remove_2)
    Storage.remove(misc_storage, "test_remove_3")

    assert Storage.get(misc_storage, :test_remove_1) === nil
    assert Storage.get(misc_storage, :test_remove_2) === nil
    assert Storage.get(misc_storage, "test_remove_3") === nil
    assert Storage.get(misc_storage, "test_remove_4") === "test_value_delete_4"
  end

  test "clear all" do
    # Use a dedicated public ETS table to avoid conflicts with misc storage data.
    process_storage = :ets.new(:test_clear_all, [:set, :public])

    Storage.insert(process_storage, "test_clear_1", "my_value")
    Storage.insert(process_storage, "test_clear_2", "my_value")

    assert Storage.get(process_storage, "test_clear_1") === "my_value"
    assert Storage.get(process_storage, "test_clear_2") === "my_value"

    Storage.clear_all(process_storage)

    assert Storage.export_all(process_storage) === []
  end

  test "export all" do
    # Use a dedicated public ETS table to avoid conflicts with misc storage data.
    process_storage = :ets.new(:test_export_all, [:set, :public])

    assert Storage.export_all(process_storage) === []

    Storage.insert(process_storage, "test_export_1", "my_value")
    Storage.insert(process_storage, "test_export_2", "my_value")

    result = Storage.export_all(process_storage)

    items = [
      {"test_export_2", "my_value"},
      {"test_export_1", "my_value"}
    ]

    assert length(result) === 2

    Enum.each(result, fn export_item ->
      assert Enum.find(items, fn item -> item == export_item end)
    end)
  end

  test "foldl accumulates over all entries" do
    process_storage = :ets.new(:test_foldl, [:set, :public])

    Storage.insert(process_storage, :key1, 10)
    Storage.insert(process_storage, :key2, 20)
    Storage.insert(process_storage, :key3, 30)

    # Sum all values using foldl
    sum = Storage.foldl(process_storage, 0, fn {_key, value}, acc -> acc + value end)
    assert sum === 60
  end

  test "foldl on empty table returns initial accumulator" do
    process_storage = :ets.new(:test_foldl_empty, [:set, :public])

    result = Storage.foldl(process_storage, :initial, fn _entry, acc -> acc end)
    assert result === :initial
  end

  test "foldl collects keys" do
    process_storage = :ets.new(:test_foldl_keys, [:set, :public])

    Storage.insert(process_storage, :alpha, "a")
    Storage.insert(process_storage, :beta, "b")
    Storage.insert(process_storage, :gamma, "c")

    keys = Storage.foldl(process_storage, [], fn {key, _value}, acc -> [key | acc] end)

    assert length(keys) === 3
    assert :alpha in keys
    assert :beta in keys
    assert :gamma in keys
  end

  test "foldl handles entries with TTL" do
    process_storage = :ets.new(:test_foldl_ttl, [:set, :public])

    Storage.insert(process_storage, :ttl_key, "ttl_value", ttl: 60_000)
    Storage.insert(process_storage, :no_ttl_key, "no_ttl_value")

    # Collect all entries - foldl sees the raw ETS tuples
    entries =
      Storage.foldl(process_storage, [], fn entry, acc -> [entry | acc] end)

    assert length(entries) === 2

    # One entry has TTL (3-tuple), one doesn't (2-tuple)
    tuple_sizes = Enum.map(entries, &tuple_size/1) |> Enum.sort()
    assert tuple_sizes === [2, 3]
  end

  test "foldl can filter entries during traversal" do
    process_storage = :ets.new(:test_foldl_filter, [:set, :public])

    Storage.insert(process_storage, :keep1, 100)
    Storage.insert(process_storage, :skip1, 5)
    Storage.insert(process_storage, :keep2, 200)
    Storage.insert(process_storage, :skip2, 3)

    # Only accumulate values >= 100
    large_values =
      Storage.foldl(process_storage, [], fn {_key, value}, acc ->
        if value >= 100, do: [value | acc], else: acc
      end)

    assert length(large_values) === 2
    assert 100 in large_values
    assert 200 in large_values
  end
end
