defmodule ProcessHub.Utility.Name do
  @moduledoc """
  Utility functions for generating names processes/ETS tables registered under
  the `hub_id`.
  """

  @doc "Concatenates the given atoms/binary with the given separator."
  @spec concat_name([atom() | binary()], binary()) :: atom()
  def concat_name(atoms, separator) do
    ["hub" | atoms]
    |> Enum.map(fn concatable ->
      cond do
        is_atom(concatable) -> Atom.to_string(concatable)
        is_binary(concatable) -> concatable
        true -> raise "concat_name: #{inspect(concatable)} is not an atom or binary"
      end
    end)
    |> Enum.join(separator)
    |> String.to_atom()
  end

  # TODO: move test from process registry to name.
  @doc "Returns the process registry table identifier."
  @spec registry(ProcessHub.hub_id()) :: atom()
  def registry(hub_id) do
    concat_name([hub_id, :process_registry], ".")
  end

  @spec worker_queue(ProcessHub.hub_id()) :: atom()
  def worker_queue(hub_id) do
    concat_name([hub_id, "worker_queue"], ".")
  end

  @doc "The name of the main initializer process."
  @spec initializer(ProcessHub.hub_id()) :: atom()
  def initializer(hub_id) do
    concat_name([hub_id, "initializer"], ".")
  end

  @doc "The name of the local event queue process."
  @spec local_event_queue(ProcessHub.hub_id()) :: atom()
  def local_event_queue(hub_id) do
    concat_name([hub_id, node(), "local_event_queue"], ".")
  end

  @doc "The name of the global event queue process."
  @spec global_event_queue(ProcessHub.hub_id()) :: atom()
  def global_event_queue(hub_id) do
    concat_name([hub_id, "global_event_queue"], ".")
  end

  @doc "The name of main coordinator process."
  @spec coordinator(ProcessHub.hub_id()) :: atom()
  def coordinator(hub_id) do
    concat_name([hub_id, "coordinator"], ".")
  end

  @doc "The name distributed supervisor process."
  @spec distributed_supervisor(ProcessHub.hub_id()) :: atom()
  def distributed_supervisor(hub_id) do
    concat_name([hub_id, "distributed_supervisor"], ".")
  end

  @doc "The name of the task supervisor process."
  @spec task_supervisor(ProcessHub.hub_id()) :: atom()
  def task_supervisor(hub_id) do
    concat_name([hub_id, "task_supervisor"], ".")
  end
end
