defmodule ProcessHub.StartResult do
  @type t() :: %__MODULE__{
          status: :ok | :error,
          started: [{ProcessHub.child_id(), [{node(), pid()}]}],
          errors: [{ProcessHub.child_id(), term()}],
          rollback: boolean()
        }
  defstruct [:status, :started, :errors, :rollback]

  def format(%__MODULE__{status: :error, errors: e, started: s, rollback: true}),
    do: {:error, {e, s}, :rollback}

  def format(%__MODULE__{status: :error, errors: e, started: s}), do: {:error, {e, s}}
  def format(%__MODULE__{status: :ok, started: s}), do: {:ok, s}
  def format({:error, reason}), do: {:error, reason}

  def errors(%__MODULE__{errors: errors}), do: errors
  def errors({:error, reason}), do: {:error, reason}

  def status(%__MODULE__{status: status}), do: status
  def status({:error, reason}), do: {:error, reason}

  def pid(%__MODULE__{started: started}) do
    case List.first(started) do
      nil -> nil
      first_item -> 
        first_item
        |> elem(1)
        |> List.first()
        |> elem(1)
    end
  end

  def pids(%__MODULE__{started: started}) do
    started
    |> Enum.flat_map(fn {_, node_pids} -> node_pids end)
    |> Enum.map(fn {_node, pid} -> pid end)
  end

  def node(%__MODULE__{started: started}) do
    case List.first(started) do
      nil -> nil
      first_item -> 
        first_item
        |> elem(1)
        |> List.first()
        |> elem(0)
    end
  end

  def nodes(%__MODULE__{started: started}) do
    started
    |> Enum.flat_map(fn {_, node_pids} -> node_pids end)
    |> Enum.map(fn {node, _pid} -> node end)
    |> Enum.uniq()
  end

  def first(%__MODULE__{started: started}) do
    List.first(started)
  end
end
