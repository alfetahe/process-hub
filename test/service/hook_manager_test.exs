defmodule Test.Service.HookManagerTest do
  alias ProcessHub.Service.HookManager

  use ExUnit.Case

  setup do
    Test.Helper.SetupHelper.setup_base(%{}, :hook_manager_test)
  end

  test "register handler", %{hub_id: hub_id} = _context do
    handler = %HookManager{
      id: :hook_manager_test_register_handler,
      m: :m,
      f: :f,
      a: []
    }

    HookManager.register_handler(hub_id, :test, handler)

    assert HookManager.registered_handlers(hub_id, :test) === [handler]
  end

  test "register handler string id", %{hub_id: hub_id} = _context do
    handler = %HookManager{
      id: "hook_manager_test_register_handler",
      m: :m,
      f: :f,
      a: []
    }

    HookManager.register_handler(hub_id, :test, handler)

    assert HookManager.registered_handlers(hub_id, :test) === [handler]
  end

  test "register handler duplicate", %{hub_id: hub_id} = _context do
    handler = %HookManager{
      id: :hook_manager_test_register_handler,
      m: :m,
      f: :f,
      a: []
    }

    HookManager.register_handler(hub_id, :test, handler)

    assert HookManager.registered_handlers(hub_id, :test) === [handler]

    assert HookManager.register_handler(hub_id, :test, handler) ===
             {:error, :handler_id_not_unique}
  end

  test "register handlers", %{hub_id: hub_id} = _context do
    handlers = [
      %HookManager{
        id: :hook_manager_test_register_handlers_1,
        m: :m,
        f: :f,
        a: [],
        p: 0
      },
      %HookManager{
        id: :hook_manager_test_register_handlers_2,
        m: :m,
        f: :f,
        a: [],
        p: 10
      }
    ]

    HookManager.register_handlers(hub_id, :test, handlers)

    assert HookManager.registered_handlers(hub_id, :test) === handlers |> Enum.reverse()
  end

  test "register handlers duplicates", %{hub_id: hub_id} = _context do
    handlers = [
      %HookManager{
        id: :hook_manager_test_register_handlers_1,
        m: :m,
        f: :f,
        a: [],
        p: 10
      },
      %HookManager{
        id: :hook_manager_test_register_handlers_2,
        m: :m,
        f: :f,
        a: [],
        p: 0
      }
    ]

    HookManager.register_handlers(hub_id, :test, handlers)

    assert HookManager.registered_handlers(hub_id, :test) === handlers

    assert HookManager.register_handlers(hub_id, :test, handlers) ===
             {:error,
              {:handler_id_not_unique,
               [
                 :hook_manager_test_register_handlers_1,
                 :hook_manager_test_register_handlers_2
               ]}}
  end

  test "dispatch hooks", %{hub_id: hub_id} = _context do
    handler = %HookManager{
      id: :hook_manager_test_dispatch_hooks,
      m: :erlang,
      f: :send,
      a: [self(), :dispatch_hooks_test_1]
    }

    HookManager.register_handler(hub_id, :test_1, handler)

    handler2 = %HookManager{
      id: :hook_manager_test_dispatch_hooks2,
      m: :erlang,
      f: :send,
      a: [self(), :_]
    }

    HookManager.register_handler(hub_id, :test_2, handler2)

    HookManager.dispatch_hooks(hub_id, [{:test_1, :hook_data}, {:test_2, :dispatch_hooks_test_2}])

    assert_receive :dispatch_hooks_test_1
    assert_receive :dispatch_hooks_test_2
  end

  test "dispatch hook", %{hub_id: hub_id} = _context do
    handler = %HookManager{
      id: :hook_manager_test_dispatch_hook,
      m: :erlang,
      f: :send,
      a: [self(), :dispatch_hook_test_1]
    }

    HookManager.register_handlers(hub_id, :test_1, [handler])

    HookManager.dispatch_hook(hub_id, :test_1, :hook_data)

    handler2 = %HookManager{
      id: :hook_manager_test_dispatch_hook,
      m: :erlang,
      f: :send,
      a: [self(), :_]
    }

    # Dispatching to separate key thats why we should not receive duplicate error.
    HookManager.register_handlers(hub_id, :test_2, [handler2])
    :ok = HookManager.dispatch_hook(hub_id, :test_2, :dispatch_hook_test_2)

    assert_receive :dispatch_hook_test_1
    assert_receive :dispatch_hook_test_2
  end

  test "cancel handler", %{hub_id: hub_id} = _context do
    handler = %HookManager{
      id: :hook_manager_test_cancel_handler,
      m: :erlang,
      f: :send,
      a: [self(), :cancel_handler_test]
    }

    handler2 = %HookManager{
      id: :hook_manager_test_cancel_handler2,
      m: :erlang,
      f: :send,
      a: [self(), :cancel_handler_test2]
    }

    HookManager.register_handlers(hub_id, :test, [handler, handler2])

    HookManager.cancel_handler(hub_id, :test, :hook_manager_test_cancel_handler)

    assert HookManager.registered_handlers(hub_id, :test) === [handler2]
  end
end
