defmodule Test.Service.HookManagerTest do
  alias ProcessHub.Service.HookManager

  use ExUnit.Case

  setup do
    Test.Helper.SetupHelper.setup_base(%{}, :hook_manager_test)
  end

  test "register handler", %{hub: hub} = _context do
    hook_table = hub.storage.hook

    handler = %HookManager{
      id: :hook_manager_test_register_handler,
      m: :m,
      f: :f,
      a: []
    }

    HookManager.register_handler(hook_table, :test, handler)

    assert HookManager.registered_handlers(hook_table, :test) === [handler]
  end

  test "register handler string id", %{hub: hub} = _context do
    hook_table = hub.storage.hook

    handler = %HookManager{
      id: "hook_manager_test_register_handler",
      m: :m,
      f: :f,
      a: []
    }

    HookManager.register_handler(hook_table, :test, handler)

    assert HookManager.registered_handlers(hook_table, :test) === [handler]
  end

  test "register handler duplicate", %{hub: hub} = _context do
    hook_table = hub.storage.hook

    handler = %HookManager{
      id: :hook_manager_test_register_handler,
      m: :m,
      f: :f,
      a: []
    }

    HookManager.register_handler(hook_table, :test, handler)

    assert HookManager.registered_handlers(hook_table, :test) === [handler]

    assert HookManager.register_handler(hook_table, :test, handler) ===
             {:error, :handler_id_not_unique}
  end

  test "register handlers", %{hub: hub} = _context do
    hook_table = hub.storage.hook

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

    HookManager.register_handlers(hook_table, :test, handlers)

    assert HookManager.registered_handlers(hook_table, :test) === handlers |> Enum.reverse()
  end

  test "register handlers duplicates", %{hub: hub} = _context do
    hook_table = hub.storage.hook

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

    HookManager.register_handlers(hook_table, :test, handlers)

    assert HookManager.registered_handlers(hook_table, :test) === handlers

    assert HookManager.register_handlers(hook_table, :test, handlers) ===
             {:error,
              {:handler_id_not_unique,
               [
                 :hook_manager_test_register_handlers_1,
                 :hook_manager_test_register_handlers_2
               ]}}
  end

  test "dispatch hooks with empty map returns ok", %{hub: hub} = _context do
    hook_table = hub.storage.hook
    assert :ok == HookManager.dispatch_hooks(hook_table, %{})
  end

  test "dispatch hooks", %{hub: hub} = _context do
    hook_table = hub.storage.hook

    handler = %HookManager{
      id: :hook_manager_test_dispatch_hooks,
      m: :erlang,
      f: :send,
      a: [self(), :dispatch_hooks_test_1]
    }

    HookManager.register_handler(hook_table, :test_1, handler)

    handler2 = %HookManager{
      id: :hook_manager_test_dispatch_hooks2,
      m: :erlang,
      f: :send,
      a: [self(), :_]
    }

    HookManager.register_handler(hook_table, :test_2, handler2)

    HookManager.dispatch_hooks(hook_table, [
      {:test_1, :hook_data},
      {:test_2, :dispatch_hooks_test_2}
    ])

    assert_receive :dispatch_hooks_test_1
    assert_receive :dispatch_hooks_test_2
  end

  test "dispatch hook", %{hub: hub} = _context do
    hook_table = hub.storage.hook

    handler = %HookManager{
      id: :hook_manager_test_dispatch_hook,
      m: :erlang,
      f: :send,
      a: [self(), :dispatch_hook_test_1]
    }

    HookManager.register_handlers(hook_table, :test_1, [handler])

    HookManager.dispatch_hook(hook_table, :test_1, :hook_data)

    handler2 = %HookManager{
      id: :hook_manager_test_dispatch_hook,
      m: :erlang,
      f: :send,
      a: [self(), :_]
    }

    # Dispatching to separate key thats why we should not receive duplicate error.
    HookManager.register_handlers(hook_table, :test_2, [handler2])
    :ok = HookManager.dispatch_hook(hook_table, :test_2, :dispatch_hook_test_2)

    assert_receive :dispatch_hook_test_1
    assert_receive :dispatch_hook_test_2
  end

  test "dispatch alter hook", %{hub: hub} = _context do
    hook_table = hub.storage.hook

    handler = %HookManager{
      id: :hook_manager_test_dispatch_hook,
      m: Enum,
      f: :sum,
      a: [:_]
    }

    HookManager.register_handlers(hook_table, :test_alter, [handler])

    altered_data = HookManager.dispatch_alter_hook(hook_table, :test_alter, [1, 2, 3])

    assert altered_data == 6
  end

  test "cancel handler", %{hub: hub} = _context do
    hook_table = hub.storage.hook

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

    HookManager.register_handlers(hook_table, :test, [handler, handler2])

    HookManager.cancel_handler(hook_table, :test, :hook_manager_test_cancel_handler)

    assert HookManager.registered_handlers(hook_table, :test) === [handler2]
  end
end
