defmodule Test.Service.StorageTest do
  alias ProcessHub.Service.Storage
  alias ProcessHub.Utility.Name

  use ExUnit.Case

  @hub_id :storage_test
  @local_storage Name.local_storage(@hub_id)

  setup do
    Test.Helper.SetupHelper.setup_base(%{}, @hub_id)
  end

  test "exists", _context do
    assert Storage.exists?(@local_storage, :test) === false

    Storage.insert(@local_storage, :test, :test_value)

    assert Storage.exists?(@local_storage, :test) === true
  end

  test "insert", _context do
    assert Storage.get(@local_storage, :test) === nil

    Storage.insert(@local_storage, :test_insert, :test_value)
    Storage.insert(@local_storage, :test_insert2, :test_value2, ttl: 5000)

    assert Storage.get(@local_storage, :test_insert) === :test_value

    value = Storage.get(@local_storage, :test_insert2)

    assert value === value
  end

  test "get", _context do
    assert Storage.get(@local_storage, :test) === nil

    Storage.insert(@local_storage, :test, :test_value)
    Storage.insert(@local_storage, :test2, :test_value2)

    assert Storage.get(@local_storage, :test) === :test_value
    assert Storage.get(@local_storage, :test2) === :test_value2
    assert Storage.get(@local_storage, :non_exist) === nil
  end

  test "update", _context do
    res1 = Storage.update(@local_storage, :not_exist_update1, fn val -> val end)
    res2 = Storage.update(@local_storage, :not_exist_update2, fn _val -> 5000 end)

    Storage.insert(@local_storage, :exist_update1, 4)
    res3 = Storage.update(@local_storage, :exist_update1, fn val -> val * 2 end)

    assert Storage.get(@local_storage, :not_exist_update1) === nil
    assert Storage.get(@local_storage, :not_exist_update2) === 5000
    assert Storage.get(@local_storage, :exist_update1) === 8

    assert res1 === true
    assert res2 === true
    assert res3 === true
  end

  test "remove", _context do
    Storage.insert(@local_storage, :test_remove_1, "test_value_delete_1")
    Storage.insert(@local_storage, :test_remove_2, "test_value_delete_2")
    Storage.insert(@local_storage, "test_remove_3", "test_value_delete_3")
    Storage.insert(@local_storage, "test_remove_4", "test_value_delete_4")

    assert Storage.get(@local_storage, :test_remove_1) === "test_value_delete_1"
    assert Storage.get(@local_storage, :test_remove_2) === "test_value_delete_2"
    assert Storage.get(@local_storage, "test_remove_3") === "test_value_delete_3"
    assert Storage.get(@local_storage, "test_remove_4") === "test_value_delete_4"

    Storage.remove(@local_storage, :test_remove_1)
    Storage.remove(@local_storage, :test_remove_2)
    Storage.remove(@local_storage, "test_remove_3")

    assert Storage.get(@local_storage, :test_remove_1) === nil
    assert Storage.get(@local_storage, :test_remove_2) === nil
    assert Storage.get(@local_storage, "test_remove_3") === nil
    assert Storage.get(@local_storage, "test_remove_4") === "test_value_delete_4"
  end

  test "clear all", _context do
    # Were not using local storage because this would result in error.
    process_storage = ProcessHub.Utility.Name.registry(@hub_id)

    Storage.insert(process_storage, "test_clear_1", "my_value")
    Storage.insert(process_storage, "test_clear_2", "my_value")

    assert Storage.get(process_storage, "test_clear_1") === "my_value"
    assert Storage.get(process_storage, "test_clear_2") === "my_value"

    Storage.clear_all(process_storage)

    assert Storage.export_all(process_storage) === []
  end

  test "export all", _context do
    # Were not using local storage because it has other required elements inside it.
    process_storage = ProcessHub.Utility.Name.registry(@hub_id)

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
end
