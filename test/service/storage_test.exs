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
end
