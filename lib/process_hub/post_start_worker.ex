defmodule ProcessHub.PostStartWorker do
  @moduledoc """
  A worker process that handles post-startup tasks after the core supervisor
  tree is initialized.

  This worker is started after `WorkerQueue` in the supervisor tree, ensuring
  all core processes are available to handle requests. Its primary responsibility
  is starting static children defined in the hub configuration.

  Starting static children from `WorkerQueue.init` would deadlock because
  `start_children` dispatches work back to `WorkerQueue` via `GenServer.cast`,
  but `WorkerQueue` cannot process casts while its `init` is blocking.
  """

  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Storage
  alias ProcessHub.Future

  use GenServer

  def start_link({hub_id, pname, misc_storage}) do
    GenServer.start_link(__MODULE__, {hub_id, misc_storage}, name: pname)
  end

  @impl true
  def init({hub_id, misc_storage}) do
    handle_static_children(hub_id, misc_storage)

    {:ok, %{hub_id: hub_id}}
  end

  defp handle_static_children(hub_id, misc_storage) do
    static_child_specs = Storage.get(misc_storage, StorageKey.staticcs())

    if length(static_child_specs) > 0 do
      res =
        ProcessHub.start_children(hub_id, static_child_specs, awaitable: true)
        |> Future.await()

      case res do
        %{status: :ok} -> :ok
        %{status: :error} -> raise RuntimeError, message: "static children startup failed."
      end
    end
  end
end
