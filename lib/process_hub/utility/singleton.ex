defmodule ProcessHub.Utility.Singleton do
  @moduledoc """
  Lifecycle helpers for per-node singleton processes whose lifetime follows a
  subsystem rather than the caller that triggers them (e.g. the leadership
  watcher and oracle manager).
  """

  @doc """
  Ensures `module`'s singleton is running, starting it linked and then unlinking
  so it outlives the caller. Tolerates a concurrently-started instance.
  `module` must expose `whereis/0` and `start_link/0`.
  """
  @spec ensure_started(module()) :: :ok
  def ensure_started(module) do
    case module.whereis() do
      nil ->
        case module.start_link() do
          {:ok, pid} -> :erlang.unlink(pid)
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end

    :ok
  end

  @doc "Stops `pid`, ignoring the exit of an already-dead process."
  @spec safe_stop(pid()) :: :ok
  def safe_stop(pid) do
    GenServer.stop(pid)
  catch
    _kind, _reason -> :ok
  end
end
