defmodule ProcessHub.Service.HookManager do
  @moduledoc """
  The hook manager service provides API functions for managing hook dispatching,
  registration, and lookup.
  """

  alias ProcessHub.Service.Storage
  alias ProcessHub.Utility.Name

  # TODO: need more dynamic way of defining those.
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
          | :post_children_start_hook
          | :pre_children_redistribution_hook
          | :coordinator_shutdown_hook
          | :process_startups_hook

  @type handler_id() :: atom()

  @type handler_priority() :: integer()

  @type t() :: %__MODULE__{
          id: handler_id(),
          m: module(),
          f: atom(),
          a: [any()],
          p: handler_priority() | nil
        }

  @type hook_handlers() :: %{
          hook_key() => [
            t()
          ]
        }

  defstruct [:id, :m, :f, :a, p: 0]

  @doc "Registers a new hook handlers."
  @spec register_handlers(ProcessHub.hub_id(), hook_key(), [t()]) ::
          :ok | {:error, {:handler_id_not_unique, [handler_id()]}}
  def register_handlers(hub_id, hook_key, hook_handlers) do
    hook_handlers = hook_handlers ++ registered_handlers(hub_id, hook_key)

    case insert_handlers(hub_id, hook_key, hook_handlers) do
      :ok -> :ok
      error -> error
    end
  end

  @doc "Registers a new hook handler."
  @spec register_handler(ProcessHub.hub_id(), hook_key(), t()) ::
          :ok | {:error, :handler_id_not_unique}
  def register_handler(hub_id, hook_key, hook_handler) do
    hook_handlers = [hook_handler | registered_handlers(hub_id, hook_key)]

    case insert_handlers(hub_id, hook_key, hook_handlers) do
      :ok -> :ok
      {:error, {:handler_id_not_unique, _}} -> {:error, :handler_id_not_unique}
    end
  end

  @doc "Returns all registered hook handlers for the given hook key"
  @spec registered_handlers(ProcessHub.hub_id(), hook_key()) :: [t()]
  def registered_handlers(hub_id, hook_key) do
    case Storage.get(Name.hook_registry(hub_id), hook_key) do
      nil -> []
      handlers -> handlers
    end
  end

  @doc "Cancels a hook handler."
  @spec cancel_handler(ProcessHub.hub_id(), hook_key(), handler_id()) :: :ok
  def cancel_handler(hub_id, hook_key, handler_id) do
    hook_handlers =
      registered_handlers(hub_id, hook_key)
      |> Enum.reject(fn handler -> handler.id == handler_id end)

    Storage.insert(Name.hook_registry(hub_id), hook_key, hook_handlers)

    :ok
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

  defp insert_handlers(hub_id, hook_key, hook_handlers) do
    # Make sure that the hook id is unique
    duplicates = duplicate_handlers(hook_handlers)
    sorted_handlers = Enum.sort_by(hook_handlers, & &1.p) |> Enum.reverse()

    cond do
      Enum.empty?(duplicates) ->
        Name.hook_registry(hub_id) |> Storage.insert(hook_key, sorted_handlers)
        :ok

      true ->
        {:error, {:handler_id_not_unique, duplicates}}
    end
  end

  defp duplicate_handlers(hook_handlers) do
    hook_handlers
    |> Enum.map(& &1.id)
    |> Enum.group_by(& &1)
    |> Enum.filter(fn {_id, handlers} -> Enum.count(handlers) > 1 end)
    |> Enum.map(&elem(&1, 0))
  end
end
