defmodule ProcessHub.Service.HookManager do
  @moduledoc """
  The hook manager service provides API functions for managing hook dispatching,
  registration, and lookup.
  """

  alias ProcessHub.Service.LoggerService
  alias ProcessHub.Service.Storage

  @type hook_key() :: atom()

  @type handler_id() :: atom() | String.t()

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
  @spec register_handlers(:ets.tid(), hook_key(), [t()]) ::
          :ok | {:error, {:handler_id_not_unique, [handler_id()]}}
  def register_handlers(hook_table, hook_key, hook_handlers) do
    hook_handlers = hook_handlers ++ registered_handlers(hook_table, hook_key)

    case insert_handlers(hook_table, hook_key, hook_handlers) do
      :ok -> :ok
      error -> error
    end
  end

  @doc "Registers a new hook handler."
  @spec register_handler(:ets.tid(), hook_key(), t()) ::
          :ok | {:error, :handler_id_not_unique}
  def register_handler(hook_table, hook_key, hook_handler) do
    hook_handlers = [hook_handler | registered_handlers(hook_table, hook_key)]

    case insert_handlers(hook_table, hook_key, hook_handlers) do
      :ok -> :ok
      {:error, {:handler_id_not_unique, _}} -> {:error, :handler_id_not_unique}
    end
  end

  @doc "Returns all registered hook handlers for the given hook key"
  @spec registered_handlers(:ets.tid(), hook_key()) :: [t()]
  def registered_handlers(hook_table, hook_key) do
    case Storage.get(hook_table, hook_key) do
      nil -> []
      handlers -> handlers
    end
  end

  @doc "Cancels a hook handler."
  @spec cancel_handler(:ets.tid(), hook_key(), handler_id()) :: :ok
  def cancel_handler(hook_table, hook_key, handler_id) do
    hook_handlers =
      registered_handlers(hook_table, hook_key)
      |> Enum.reject(fn handler -> handler.id == handler_id end)

    Storage.insert(hook_table, hook_key, hook_handlers)

    :ok
  end

  @doc "Dispatches multiple hooks to the registered handlers."
  @spec dispatch_hooks(:ets.tid(), [t()]) :: :ok
  def dispatch_hooks(_hook_table, %{}), do: :ok

  def dispatch_hooks(hook_table, hooks) do
    Enum.each(hooks, fn {hook_key, hook_data} ->
      dispatch_hook(hook_table, hook_key, hook_data)
    end)

    :ok
  end

  @doc """
  Dispatches the hook to the registered handlers and passes the hook data as an argument.

  It is possible to register a hook handler with a wildcard argument `:_` which
  will be replaced with the hook data when the hook is dispatched.
  """
  @spec dispatch_hook(:ets.tid(), hook_key(), any()) :: :ok
  def dispatch_hook(hook_table, hook_key, hook_data) do
    registered_handlers(hook_table, hook_key)
    |> Enum.each(fn hook_handler ->
      exec_hook(hook_handler, hook_data)
    end)

    :ok
  end

  @doc """
  Dispatches the hook synchronously, awaiting each handler's reply before moving
  to the next, so a handler can block the caller until its own prerequisites are
  ready.

  Handlers run in registered order under a shared `total_timeout_ms` budget; each
  gets whatever remains of it. Every handler is isolated: one that raises,
  throws, crashes, or outruns its slice is logged at WARN and the dispatch
  continues, so a misbehaving handler can neither crash the caller nor hang it
  past the budget.
  """
  @spec dispatch_hook_blocking(:ets.tid(), hook_key(), any(), pos_integer()) :: :ok
  def dispatch_hook_blocking(hook_table, hook_key, hook_data, total_timeout_ms) do
    started_at = System.monotonic_time(:millisecond)

    registered_handlers(hook_table, hook_key)
    |> Enum.each(fn hook_handler ->
      elapsed = System.monotonic_time(:millisecond) - started_at
      exec_hook_blocking(hook_handler, hook_data, max(total_timeout_ms - elapsed, 0))
    end)

    :ok
  end

  @doc """
  Executes the hook handlers and lets each handler modify the hook data.

  It is possible to register a hook handler with a wildcard argument `:_` which
  will be replaced with the hook data when the hook is dispatched.

  Works similar to `dispatch_hook/3` but each handler is expected to return the modified
  hook data. The hook data is passed to the next handler in the chain.
  """
  @spec dispatch_alter_hook(:ets.tid(), hook_key(), any()) :: any()
  def dispatch_alter_hook(hook_table, hook_key, hook_data) do
    registered_handlers(hook_table, hook_key)
    |> Enum.reduce(hook_data, fn hook_handler, acc ->
      exec_hook(hook_handler, acc)
    end)
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

  defp exec_hook_blocking(handler, _hook_data, 0) do
    log_handler_error(:budget_exhausted, handler.id, nil)
  end

  defp exec_hook_blocking(handler, hook_data, timeout) do
    worker = fn ->
      try do
        exec_hook(handler, hook_data)
      rescue
        error -> {:__hook_raised__, error, __STACKTRACE__}
      catch
        kind, value -> {:__hook_caught__, kind, value, __STACKTRACE__}
      end
    end

    case await_worker(worker, timeout) do
      {:ok, {:__hook_raised__, error, stacktrace}} ->
        log_handler_error(:raised, handler.id, {error, stacktrace})

      {:ok, {:__hook_caught__, kind, value, _stacktrace}} ->
        log_handler_error(:caught, handler.id, {kind, value})

      {:ok, _result} ->
        :ok

      {:down, :normal} ->
        :ok

      {:down, reason} ->
        log_handler_error(:crashed, handler.id, reason)

      :timeout ->
        log_handler_error(:timeout, handler.id, timeout)
    end
  end

  # Runs `worker` in a monitored process and waits up to `timeout` ms for its
  # result. A still-running worker is killed on timeout so a blocked handler
  # cannot outlive its budget.
  defp await_worker(worker, timeout) do
    parent = self()
    ref = make_ref()

    {pid, mon_ref} = spawn_monitor(fn -> send(parent, {ref, worker.()}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(mon_ref, [:flush])
        {:ok, result}

      {:DOWN, ^mon_ref, :process, ^pid, reason} ->
        {:down, reason}
    after
      timeout ->
        Process.demonitor(mon_ref, [:flush])
        Process.exit(pid, :kill)
        :timeout
    end
  end

  defp log_handler_error(:budget_exhausted, id, _detail) do
    warn_handler("Skipping blocking hook handler @id — total budget exhausted", id, %{})
  end

  defp log_handler_error(:raised, id, {error, stacktrace}) do
    warn_handler("Blocking hook handler @id raised: @error", id, %{
      "error" => Exception.format(:error, error, stacktrace)
    })
  end

  defp log_handler_error(:caught, id, {kind, value}) do
    warn_handler("Blocking hook handler @id caught @kind: @value", id, %{
      "kind" => Atom.to_string(kind),
      "value" => inspect(value)
    })
  end

  defp log_handler_error(:crashed, id, reason) do
    warn_handler("Blocking hook handler @id crashed: @reason", id, %{"reason" => inspect(reason)})
  end

  defp log_handler_error(:timeout, id, timeout) do
    warn_handler("Blocking hook handler @id timed out after @ms ms", id, %{
      "ms" => Integer.to_string(timeout)
    })
  end

  defp warn_handler(message, id, params) do
    LoggerService.warning(message, Map.put(params, "id", inspect(id)), prefix: "HookManager")
  end

  defp insert_handlers(hook_table, hook_key, hook_handlers) do
    # Make sure that the hook id is unique
    duplicates = duplicate_handlers(hook_handlers)
    sorted_handlers = Enum.sort_by(hook_handlers, & &1.p) |> Enum.reverse()

    cond do
      Enum.empty?(duplicates) ->
        Storage.insert(hook_table, hook_key, sorted_handlers)
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
