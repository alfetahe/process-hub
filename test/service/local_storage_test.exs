defmodule Test.Service.LocalStorageTest do
  alias ProcessHub.Service.LocalStorage

  use ExUnit.Case

  setup do
    Test.Helper.SetupHelper.setup_base(%{}, :local_storage_test)
  end

  test "exists", %{hub_id: hub_id} = _context do
    assert LocalStorage.exists?(hub_id, :test) === false

    LocalStorage.insert(hub_id, :test, :test_value)

    assert LocalStorage.exists?(hub_id, :test) === true
  end

  test "insert", %{hub_id: hub_id} = _context do
    assert LocalStorage.get(hub_id, :test) === nil

    LocalStorage.insert(hub_id, :test_insert, :test_value)
    LocalStorage.insert(hub_id, :test_insert2, :test_value2, 5000)

    assert LocalStorage.get(hub_id, :test_insert) === :test_value

    value = LocalStorage.get(hub_id, :test_insert2)

    assert value === value
  end

  test "get", %{hub_id: hub_id} = _context do
    assert LocalStorage.get(hub_id, :test) === nil

    LocalStorage.insert(hub_id, :test, :test_value)
    LocalStorage.insert(hub_id, :test2, :test_value2)

    assert LocalStorage.get(hub_id, :test) === :test_value
    assert LocalStorage.get(hub_id, :test2) === :test_value2
    assert LocalStorage.get(hub_id, :non_exist) === nil
  end

  test "update", %{hub_id: hub_id} = _context do
    res1 = LocalStorage.update(hub_id, :not_exist_update1, fn val -> val end)
    res2 = LocalStorage.update(hub_id, :not_exist_update2, fn _val -> 5000 end)

    LocalStorage.insert(hub_id, :exist_update1, 4)
    res3 = LocalStorage.update(hub_id, :exist_update1, fn val -> val * 2 end)

    assert LocalStorage.get(hub_id, :not_exist_update1) === nil
    assert LocalStorage.get(hub_id, :not_exist_update2) === 5000
    assert LocalStorage.get(hub_id, :exist_update1) === 8

    assert res1 === {:commit, nil}
    assert res2 === {:commit, 5000}
    assert res3 === {:commit, 8}
  end
end
