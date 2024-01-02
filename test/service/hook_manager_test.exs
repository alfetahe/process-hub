defmodule Test.Service.HookManagerTest do
  alias ProcessHub.Service.HookManager

  use ExUnit.Case

  setup do
    Test.Helper.SetupHelper.setup_base(%{}, :hook_manager_test)
  end

  test "cache key" do
    assert HookManager.cache_key() === :hooks
  end

  test "register handler", %{hub_id: hub_id} = _contexxt do
    mfa = {:m, :f, :a}
    HookManager.register_handler(hub_id, :test, mfa)

    assert HookManager.registered_handlers(hub_id) === %{test: [mfa]}
  end

  test "registered handler", %{hub_id: hub_id} = _contexxt do
    assert HookManager.registered_handlers(hub_id) === %{}

    mfa = {:ma, :ff, :aa}
    HookManager.register_handler(hub_id, :test, mfa)

    assert HookManager.registered_handlers(hub_id) === %{test: [mfa]}
  end

  test "dispatch hooks", %{hub_id: hub_id} = _context do
    HookManager.register_handler(
      hub_id,
      :test_1,
      {:erlang, :send, [self(), :dispatch_hooks_test_1]}
    )

    HookManager.register_handler(hub_id, :test_2, {:erlang, :send, [self(), :_]})

    HookManager.dispatch_hooks(hub_id, [{:test_1, :hook_data}, {:test_2, :dispatch_hooks_test_2}])

    assert_receive :dispatch_hooks_test_1
    assert_receive :dispatch_hooks_test_2
  end

  test "dispatch hook", %{hub_id: hub_id} = _context do
    HookManager.register_handler(
      hub_id,
      :test_1,
      {:erlang, :send, [self(), :dispatch_hook_test_1]}
    )

    HookManager.dispatch_hook(hub_id, :test_1, :hook_data)

    HookManager.register_handler(hub_id, :test_2, {:erlang, :send, [self(), :_]})
    :ok = HookManager.dispatch_hook(hub_id, :test_2, :dispatch_hook_test_2)

    assert_receive :dispatch_hook_test_1
    assert_receive :dispatch_hook_test_2
  end
end
