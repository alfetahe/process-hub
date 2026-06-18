defmodule ProcessHub.DistributedSupervisor do
  @moduledoc """
  The `ProcessHub` distributed supervisor module is responsible for starting and stopping
  the child processes distributed across the cluster.

  Each `ProcessHub` instance has its own distributed supervisor that manages local
  child processes.
  """

  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Coordinator
  alias ProcessHub.Request.Handler.PidsUnregisterRequest
  alias ProcessHub.Request.Handler.PidUpdateRequest

  use ProcessHub.Constant.Event

  use ProcessHub.Utility.Injector,
    override: [:init, :start_link, :terminate_child, :start_child],
    base_module: :supervisor

  @pd_cid_to_pid :ph_cid_to_pid

  @doc """
  Starts the distributed supervisor with the given arguments.

  We will call the `GenServer.start_link/3` and register our current module
  as the base module, this way we can overwrite the `handle_info/2` function
  on the `:supervisor` module to handle the `:EXIT` messages our selves.
  """
  def start_link({hub_id, dsup_name, max_restarts, max_seconds}) do
    args = %{
      hub_id: hub_id,
      max_restarts: max_restarts,
      max_seconds: max_seconds
    }

    GenServer.start_link(__MODULE__, {dsup_name, __MODULE__, args}, name: dsup_name)
  end

  @doc """
  Initializes the distributed supervisor with the given arguments.

  We will call the Erlang `:supervisor` init/1 function with the given arguments.
  this in turn will call the `init/1`
  """
  def init({sup, mod, args}), do: :supervisor.init({sup, mod, args})

  def init(args) do
    # Store hub_id in process dictionary for later retrieval
    Process.put(:hub_id, args.hub_id)
    Process.put(@pd_cid_to_pid, %{})

    children =
      args.hub_id
      |> children()
      |> Enum.map(&wrap_child_spec/1)

    Supervisor.init(children,
      strategy: :one_for_one,
      auto_shutdown: :never,
      max_restarts: args.max_restarts,
      max_seconds: args.max_seconds
    )
  end

  @doc "Starts a child process on local node."
  def start_child(distributed_sup, child_spec) do
    Supervisor.start_child(distributed_sup, wrap_child_spec(child_spec))
  end

  @doc """
  Stops a child process on local node by first terminating the process and then
  deleting it from the supervisor child spec list.
  """
  def terminate_child(distributed_sup, child_id) do
    Supervisor.terminate_child(distributed_sup, child_id)
    Supervisor.delete_child(distributed_sup, child_id)
  end

  # @doc """
  # Returns only the child IDs that are currently running (have a valid PID).
  # This filters out children that are :undefined or {:restarting, _}.
  # """
  # @spec running_child_ids(supervisor :: GenServer.server()) :: [term()]
  # def running_child_ids(supervisor) do
  #   GenServer.call(supervisor, :running_child_ids)
  # end

  defp children(hub_id) do
    ProcessRegistry.local_child_specs(hub_id)
  end

  defp wrap_child_spec(child_spec) do
    spec = Supervisor.child_spec(child_spec, [])
    {mod, fun, args} = spec.start
    modules = Map.get(spec, :modules, [mod])

    spec
    |> Map.put(:modules, modules)
    |> Map.put(:start, {__MODULE__, :start_proxy, [spec.id, {mod, fun, args}]})
  end

  @doc false
  def start_proxy(child_id, {mod, fun, args}) do
    case apply(mod, fun, args) do
      {:ok, pid} ->
        register_child_pid(child_id, pid)
        {:ok, pid}

      {:ok, pid, info} ->
        register_child_pid(child_id, pid)
        {:ok, pid, info}

      error ->
        error
    end
  end

  defp register_child_pid(child_id, pid) do
    cid_to_pid = Process.get(@pd_cid_to_pid, %{})
    Process.put(@pd_cid_to_pid, Map.put(cid_to_pid, child_id, pid))
  end

  @doc """
  Handles the process exit messages for the child processes.

  We delegate the work the the `:supervisor` handle_info/2 function and then
  propagate the event to the `Dispatcher` module to notify the other nodes
  about the child process failure.
  """
  def handle_info({:EXIT, pid, _reason} = request, state) do
    # Look up child_id from pid via reverse scan (only on EXIT)
    cid_to_pid = Process.get(@pd_cid_to_pid, %{})
    child_id = Enum.find_value(cid_to_pid, fn {cid, p} -> if p === pid, do: cid end)

    # Remove old mapping
    if child_id do
      Process.put(@pd_cid_to_pid, Map.delete(cid_to_pid, child_id))
    end

    # Delegate to supervisor (may trigger restart → start_proxy updates map)
    result = :supervisor.handle_info(request, state)

    # Check outcome via map
    if child_id do
      handle_child_exit(child_id, pid)
    end

    result
  end

  # Asynchronous function to handle the child specification removal.
  def handle_info({:delete_child_spec, child_id}, state) do
    case :supervisor.handle_call({:delete_child, child_id}, nil, state) do
      {:reply, _res, new_state} ->
        {:noreply, new_state}

      {:reply, _res, new_state, _timeout} ->
        {:noreply, new_state}
    end
  end

  defp handle_child_exit(child_id, old_pid) do
    hub_id = Process.get(:hub_id)

    hub =
      try do
        Coordinator.get_hub(hub_id)
      catch
        :exit, _ -> nil
      end

    if hub do
      new_pid = Process.get(@pd_cid_to_pid, %{}) |> Map.get(child_id)

      cond do
        is_pid(new_pid) and new_pid !== old_pid ->
          handle_child_restart(hub, child_id, new_pid)

        is_nil(new_pid) ->
          handle_child_removal(hub, child_id)

        true ->
          nil
      end
    end
  end

  defp handle_child_removal(hub, child_id) do
    request = PidsUnregisterRequest.new([{child_id, [node()]}])

    Dispatcher.propagate_event(hub, request, members: :global)

    Process.send(self(), {:delete_child_spec, child_id}, [])
  end

  defp handle_child_restart(hub, child_id, new_pid) do
    request = PidUpdateRequest.new(child_id, node(), new_pid)

    Dispatcher.propagate_event(hub, request, members: :global)
  end
end
