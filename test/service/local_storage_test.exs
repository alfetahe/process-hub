defmodule Test.Service.LocalStorageTest do
  alias ProcessHub.Service.Storage

  use ExUnit.Case

  setup do
    Test.Helper.SetupHelper.setup_base(%{}, :local_storage_test)
  end

  test "exists", %{hub_id: hub_id} = _context do
    assert Storage.exists?(hub_id, :test) === false

    Storage.insert(hub_id, :test, :test_value)

    assert Storage.exists?(hub_id, :test) === true
  end

  test "insert", %{hub_id: hub_id} = _context do
    assert Storage.get(hub_id, :test) === nil

    Storage.insert(hub_id, :test_insert, :test_value)
    Storage.insert(hub_id, :test_insert2, :test_value2, 5000)

    assert Storage.get(hub_id, :test_insert) === :test_value

    value = Storage.get(hub_id, :test_insert2)

    assert value === value
  end

  test "get", %{hub_id: hub_id} = _context do
    assert Storage.get(hub_id, :test) === nil

    Storage.insert(hub_id, :test, :test_value)
    Storage.insert(hub_id, :test2, :test_value2)

    assert Storage.get(hub_id, :test) === :test_value
    assert Storage.get(hub_id, :test2) === :test_value2
    assert Storage.get(hub_id, :non_exist) === nil
  end

  test "update", %{hub_id: hub_id} = _context do
    res1 = Storage.update(hub_id, :not_exist_update1, fn val -> val end)
    res2 = Storage.update(hub_id, :not_exist_update2, fn _val -> 5000 end)

    Storage.insert(hub_id, :exist_update1, 4)
    res3 = Storage.update(hub_id, :exist_update1, fn val -> val * 2 end)

    assert Storage.get(hub_id, :not_exist_update1) === nil
    assert Storage.get(hub_id, :not_exist_update2) === 5000
    assert Storage.get(hub_id, :exist_update1) === 8

    assert res1 === {:commit, nil}
    assert res2 === {:commit, 5000}
    assert res3 === {:commit, 8}
  end
end
