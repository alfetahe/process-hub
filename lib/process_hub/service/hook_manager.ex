defmodule ProcessHub.Service.HookManager do
  @moduledoc """
  The hook manager service provides API functions for managing hook dispatching,
  registration, and lookup.
  """

  alias ProcessHub.Utility.Name

  @type hook_key() ::
          :pre_cluster_join_hook
          | :post_cluster_join_hook
          | :pre_cluster_leave_hook
          | :post_cluster_leave_hook
          | :registry_pid_insert_hook
          | :registry_pid_remove_hook
          | :child_migrated_hook
          | :forwarded_migration_hook
          | :priority_state_updated_hook
          | :pre_nodes_redistribution_hook
          | :post_nodes_redistribution_hook
          | :pre_children_start_hook

  @type hook_handler() :: {module(), atom(), [any()]}

  @type hook_handlers() :: %{
          hook_key() => [
            hook_handler()
          ]
        }

  @doc "Registers a new hook handler."
  @spec register_hook_handlers(ProcessHub.hub_id(), hook_key(), [hook_handler()]) ::
          {atom(), boolean()}
  def register_hook_handlers(hub_id, hook_key, hook_handlers) do
    hook_handlers = registered_handlers(hub_id, hook_key) ++ hook_handlers

    Name.hook_registry(hub_id) |> Cachex.put(hook_key, hook_handlers)
  end

  @doc "Returns all registered hook handlers for the given hook key"
  @spec registered_handlers(ProcessHub.hub_id(), hook_key()) :: [hook_handler()]
  def registered_handlers(hub_id, hook_key) do
    {:ok, res} = Name.hook_registry(hub_id) |> Cachex.get(hook_key)

    case res do
      nil -> []
      handlers -> handlers
    end
  end

  @doc "Dispatches multiple hooks to the registered handlers."
  @spec dispatch_hooks(ProcessHub.hub_id(), [hook_handler()]) :: :ok
  def dispatch_hooks(_hub_id, %{}), do: :ok

  def dispatch_hooks(hub_id, hooks) do
    Enum.each(hooks, fn {hook_key, hook_data} ->
      dispatch_hook(hub_id, hook_key, hook_data)
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
    registered_handlers(hub_id, hook_key)
    |> Enum.each(fn hook_handler ->
      exec_hook(hook_handler, hook_data)
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
