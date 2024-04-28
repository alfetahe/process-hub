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
          | :children_migrated_hook
          | :forwarded_migration_hook
          | :priority_state_updated_hook
          | :pre_nodes_redistribution_hook
          | :post_nodes_redistribution_hook
          | :pre_children_start_hook

  @type handler_id() :: atom()

  @type t() :: %__MODULE__{
    id: handler_id(),
    m: module(),
    f: atom(),
    a: [any()]
  }

  @type hook_handlers() :: %{
          hook_key() => [
            t()
          ]
        }

  defstruct [:id, :m, :f, :a]

  @doc "Registers a new hook handler."
  @spec register_handlers(ProcessHub.hub_id(), hook_key(), [t()]) :: :ok | :error
  def register_handlers(hub_id, hook_key, hook_handlers) do
    hook_handlers = registered_handlers(hub_id, hook_key) ++ hook_handlers

    insert_hooks(hub_id, hook_key, hook_handlers)
  end

  # TODO: add tests
  @spec register_handler(ProcessHub.hub_id(), hook_key(), t()) :: :ok | :error
  def register_handler(hub_id, hook_key, hook_handler) do
    hook_handlers = [registered_handlers(hub_id, hook_key) | hook_handler]

    insert_hooks(hub_id, hook_key, hook_handlers)
  end

  @doc "Returns all registered hook handlers for the given hook key"
  @spec registered_handlers(ProcessHub.hub_id(), hook_key()) :: [t()]
  def registered_handlers(hub_id, hook_key) do
    {:ok, res} = Name.hook_registry(hub_id) |> Cachex.get(hook_key)

    case res do
      nil -> []
      handlers -> handlers
    end
  end

  @doc "Dispatches multiple hooks to the registered handlers."
  @spec dispatch_hooks(ProcessHub.hub_id(), [t()]) :: :ok
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

  defp exec_hook(%__MODULE__{m: module, f: func, a: args}, hook_data) do
    args =
      Enum.map(args, fn arg ->
        case arg do
          :_ ->
            hook_data

          _ ->
            arg
        end
      end)

    apply(module, func, args)
  end

  defp insert_hooks(hub_id, hook_key, hook_handlers) do
    res = Cachex.put(
      Name.hook_registry(hub_id),
      hook_key,
      hook_handlers
    )

    case res do
      {:ok, _} -> :ok
      _ -> :error
    end
  end
end
