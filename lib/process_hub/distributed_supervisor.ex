defmodule ProcessHub.DistributedSupervisor do
  @moduledoc """
  The `ProcessHub` distributed supervisor module is responsible for starting and stopping
  the child processes distributed across the cluster.

  Each `ProcessHub` instance has its own distributed supervisor that manages local
  child processes.
  """

  alias ProcessHub.Service.ProcessRegistry

  use Supervisor

  @type pname() :: atom()

  def start_link({hub_id, managers}) do
    Supervisor.start_link(__MODULE__, hub_id, name: managers.distributed_supervisor)
  end

  @impl true
  def init(hub_id) do
    children = children(hub_id)

    Supervisor.init(children, strategy: :one_for_one)
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
end
