defmodule ProcessHub.DistributedSupervisor do
  @moduledoc """
  The `ProcessHub` distributed supervisor module is responsible for starting and stopping
  the child processes distributed across the cluster.

  Each `ProcessHub` instance has its own distributed supervisor that manages local
  child processes.
  """

  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Utility.Name
  alias ProcessHub.Constant.PriorityLevel

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
  def start_link({hub_id, %{distributed_supervisor: sup}}) do
    GenServer.start_link(__MODULE__, {sup, __MODULE__, hub_id}, name: sup)
  end

  @doc """
  Initializes the distributed supervisor with the given arguments.

  We will call the Erlang `:supervisor.init/1` function with the given arguments.
  this in turn will call the `init/1`
  """
  def init({sup, mod, args}), do: :supervisor.init({sup, mod, args})

  def init(hub_id) do
    Supervisor.init(children(hub_id), strategy: :one_for_one)
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
  def handle_info({:EXIT, pid, reason} = request, state) do
    case :supervisor.handle_info(request, state) do
      {:noreply, new_state} ->
        old_child_info =
          case reason do
            :normal -> nil
            _ -> extract_child_info(state, pid)
          end

        case old_child_info do
          {child_id, info} ->
            new_pid = elem(info, 1)

            Process.sleep(500)

            Dispatcher.propagate_event(
              Name.extract_hub_id(elem(state, 1)),
              @event_child_failure_restart,
              {child_id, {node(), new_pid}},
              %{
                members: :global,
                priority: PriorityLevel.locked()
              }
            )

          _ ->
            nil
        end

        {:noreply, new_state}

      {:shutdown, new_state} ->
        {:shutdown, new_state}
    end
  end

  defp extract_child_info(state, down_pid) do
    state
    |> elem(3)
    |> elem(1)
    |> Enum.find(fn {_key, child_info} ->
      prev_pid = elem(child_info, 1)
      down_pid === prev_pid
    end)
  end
end
