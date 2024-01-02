defmodule ProcessHub.Service.HookManager do
  @moduledoc """
  The hook manager service provides API functions for managing hook dispatching,
  registration, and lookup.
  """

  alias ProcessHub.Service.LocalStorage

  @type hook_key() ::
          :cluster_join_hook
          | :cluster_leave_hook
          | :registry_pid_insert_hook
          | :registry_pid_remove_hook
          | :child_migrated_hook
          | :forwarded_migration_hook
          | :priority_state_updated_hook
          | :pre_nodes_redistribution_hook
          | :post_nodes_redistribution_hook

  @type hook() :: {module(), atom(), [any()]}

  @type hooks() :: %{
          hook_key() => [
            hook()
          ]
        }

  @doc "Returns the cache key for the hook manager."
  @spec cache_key :: :hooks
  def cache_key() do
    :hooks
  end

  @doc "Registers a new hook handler."
  @spec register_handler(ProcessHub.hub_id(), hook_key(), hook()) :: true
  def register_handler(hub_id, hook_key, hook) do
    hooks =
      case LocalStorage.get(hub_id, cache_key()) do
        nil -> %{}
        hooks -> hooks
      end

    handlers = hooks[hook_key] || []
    new_handlers = [hook | handlers]
    new_hooks = Map.put(hooks, hook_key, new_handlers)

    LocalStorage.insert(hub_id, cache_key(), new_hooks)
  end

  @doc "Returns all registered hook handlers sorted by hook key."
  @spec registered_handlers(ProcessHub.hub_id()) :: hooks()
  def registered_handlers(hub_id) do
    cache_key = cache_key()

    LocalStorage.get(hub_id, cache_key)
    |> case do
      nil ->
        %{}

      hooks ->
        case is_map(hooks) do
          true -> hooks
          false -> %{}
        end
    end
  end

  @doc "Dispatches multiple hooks to the registered handlers."
  @spec dispatch_hooks(ProcessHub.hub_id(), [hook()]) :: :ok
  def dispatch_hooks(_hub_id, %{}), do: :ok

  def dispatch_hooks(hub_id, hooks) do
    registered_handlers = registered_handlers(hub_id)

    Enum.each(hooks, fn {hook_key, hook_data} ->
      key_hooks = registered_handlers[hook_key] || []

      Enum.each(key_hooks, fn hook ->
        exec_hook(hook, hook_data)
      end)
    end)

    :ok
  end

  @doc """
  Dispatches the hook to the registered handlers and passes the hook data as an argument.

  It is possible to register a hook handler with a wildcard argument `:_` which
  will be replaced with the hook data when the hook is dispatched.
  """
  @spec dispatch_hook(ProcessHub.hub_id(), hook_key(), any()) :: :ok
  def dispatch_hook(hub_id, hook_key, hook_data) do
    registered_handlers = registered_handlers(hub_id)

    key_hooks = registered_handlers[hook_key] || []

    Enum.each(key_hooks, fn hook ->
      exec_hook(hook, hook_data)
    end)

    :ok
  end

  defp exec_hook({m, f, a}, hook_data) do
    args =
      Enum.map(a, fn arg ->
        case arg do
          :_ ->
            hook_data

          _ ->
            arg
        end
      end)

    apply(m, f, args)
  end
end
