defmodule ProcessHub.DistributedSupervisor do
  @moduledoc """
  The `ProcessHub` distributed supervisor module is responsible for starting and stopping
  the child processes distributed across the cluster.

  Each `ProcessHub` instance has its own distributed supervisor that manages local
  child processes.
  """

  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Constant.PriorityLevel
  alias ProcessHub.Coordinator

  use ProcessHub.Constant.Event

  use ProcessHub.Injector,
    override: [:init, :start_link, :terminate_child, :start_child],
    base_module: :supervisor

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

  We will call the Erlang `:supervisor.init/1` function with the given arguments.
  this in turn will call the `init/1`
  """
  def init({sup, mod, args}), do: :supervisor.init({sup, mod, args})

  def init(args) do
    # Store hub_id in process dictionary for later retrieval
    Process.put(:hub_id, args.hub_id)

    Supervisor.init(children(args.hub_id),
      strategy: :one_for_one,
      auto_shutdown: :never,
      max_restarts: args.max_restarts,
      max_seconds: args.max_seconds
    )
  end

  @doc "Starts a child process on local node."
  def start_child(distributed_sup, child_spec) do
    Supervisor.start_child(distributed_sup, child_spec)
  end

  @doc """
  Stops a child process on local node by first terminating the process and then
  deleting it from the supervisor child spec list.
  """
  def terminate_child(distributed_sup, child_id) do
    Supervisor.terminate_child(distributed_sup, child_id)
    Supervisor.delete_child(distributed_sup, child_id)
  end

  @doc "Returns `true` if the child process is running on local node."
  def has_child?(distributed_sup, child_id) do
    Supervisor.which_children(distributed_sup)
    |> Enum.map(&elem(&1, 0))
    |> Enum.member?(child_id)
  end

  @doc "Returns the child process pid if it is running on local node."
  def local_pid(distributed_sup, child_id) do
    Supervisor.which_children(distributed_sup)
    |> Enum.find({nil, nil}, &(elem(&1, 0) === child_id))
    |> elem(1)
    |> dbg()
  end

  @doc "Returns a list of processe pairs in the form of `{child_id, pid}`
  that are running on local node."
  def local_children(distributed_sup) do
    Supervisor.which_children(distributed_sup)
    |> Enum.map(fn {child_id, pid, _, _} -> {child_id, pid} end)
    |> Map.new()
  end

  @spec local_child_ids(atom() | pid() | {atom(), any()} | {:via, atom(), any()}) :: list()
  @doc "Returns the child process ids that are running on local node."
  def local_child_ids(distributed_sup) do
    Supervisor.which_children(distributed_sup)
    |> Enum.map(fn {child_id, _, _, _} -> child_id end)
  end

  defp children(hub_id) do
    ProcessRegistry.local_child_specs(hub_id)
  end

  @doc """
  Handles the process exit messages for the child processes.

  We delegate the work the the `:supervisor.handle_info/2` function and then
  propagate the event to the `Dispatcher` module to notify the other nodes
  about the child process failure.
  """
  def handle_info({:EXIT, pid, _reason} = request, state) do
    case :supervisor.handle_info(request, state) do
      {:noreply, new_state} ->
        handle_child_exit(state, new_state, pid)
        {:noreply, new_state}

      {:noreply, new_state, timeout} ->
        handle_child_exit(state, new_state, pid)
        {:noreply, new_state, timeout}

      {:stop, reason, new_state} ->
        handle_child_exit(state, new_state, pid)
        {:stop, reason, new_state}
    end
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

  defp handle_child_exit(old_state, new_state, pid) do
    hub_id = Process.get(:hub_id)

    # Get hub state, but handle case where coordinator is shutting down
    hub =
      try do
        Coordinator.get_hub(hub_id)
      catch
        :exit, _ -> nil
      end

    # If coordinator is unavailable, skip handling (system is shutting down)
    if hub == nil do
      :ok
    else
      cid = find_cid_from_pid(old_state, pid)
      old_pid = find_pid_from_cid(old_state, cid)
      new_pid = find_pid_from_cid(new_state, cid)

      cond do
        # No new pid found, the child process has been terminated.
        new_pid === :undefined ->
          handle_child_removal(hub.procs.event_queue, cid)

        # The child process has been restarted with a new pid.
        is_pid(new_pid) and old_pid !== new_pid ->
          handle_child_restart(hub.procs.event_queue, cid, new_pid)

        true ->
          nil
      end
    end
  end

  defp handle_child_removal(event_queue, child_id) do
    node = node()

    Dispatcher.propagate_event(
      event_queue,
      @event_children_unregistration,
      {[{child_id, :self_exit, node}], node, []},
      %{
        members: :global,
        priority: PriorityLevel.locked()
      }
    )

    # Deletes the child specification from the supervisor by sending an asynchrounous request
    # to the Supervisor process itself.
    Process.send(self(), {:delete_child_spec, child_id}, [])
  end

  defp handle_child_restart(event_queue, child_id, new_pid) do
    Dispatcher.propagate_event(
      event_queue,
      @event_child_process_pid_update,
      {child_id, {node(), new_pid}},
      %{
        members: :global,
        priority: PriorityLevel.locked()
      }
    )
  end

  defp find_cid_from_pid(state, compare_pid) do
    state
    |> elem(3)
    |> elem(1)
    |> Enum.find(fn {_key, child_info} ->
      pid_from_state = elem(child_info, 1)
      pid_from_state === compare_pid
    end)
    |> elem(0)
  end

  defp find_pid_from_cid(state, compare_cid) do
    # Format of the state is defined as a staterecord in the `:supervisor` module.
    # {_, _, _, {_, %{^child_id =>  {_, pid, _cid, _, _, _, _, _, _}}}, _, _, _, _, _, _, _, _} = state

    state
    |> elem(3)
    |> elem(1)
    |> Enum.find(fn {state_cid, _} ->
      state_cid === compare_cid
    end)
    |> elem(1)
    |> elem(1)
  end
end
