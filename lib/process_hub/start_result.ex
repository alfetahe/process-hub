defmodule ProcessHub.StartResult do
  @moduledoc """
  A struct representing the result of starting child processes across multiple nodes.

  This module provides utilities for formatting and extracting information from
  start operation results, including successful starts, errors, and rollback scenarios.
  """

  @type t() :: %__MODULE__{
          status: :ok | :error,
          started: [{ProcessHub.child_id(), [{node(), pid()}]}],
          errors: [{ProcessHub.child_id(), term()}],
          rollback: boolean()
        }

  @type error_input :: {:error, term()}

  defstruct [:status, :started, :errors, :rollback]

  @doc """
  Formats a StartResult struct into a standardized tuple format.

  ## Parameters
    - `result` - A StartResult struct or error tuple

  ## Returns
    - `{:ok, started}` for successful operations
    - `{:error, {errors, started}}` for failed operations
    - `{:error, {errors, started}, :rollback}` for failed operations with rollback
    - `{:error, reason}` for error tuples

  ## Examples
      iex> result = %ProcessHub.StartResult{status: :ok, started: [{"child1", [node1: pid]}]}
      iex> ProcessHub.StartResult.format(result)
      {:ok, [{"child1", [node1: pid]}]}

      iex> ProcessHub.StartResult.format({:error, :timeout})
      {:error, :timeout}
  """
  @spec format(t() | error_input()) ::
          {:ok, term()}
          | {:error, {term(), term()}}
          | {:error, {term(), term()}, :rollback}
          | {:error, term()}
  def format(%__MODULE__{status: :error, errors: e, started: s, rollback: true}),
    do: {:error, {e, s}, :rollback}

  def format(%__MODULE__{status: :error, errors: e, started: s}), do: {:error, {e, s}}
  def format(%__MODULE__{status: :ok, started: s}), do: {:ok, s}
  def format({:error, reason}), do: {:error, reason}

  @doc """
  Extracts the errors from a StartResult struct or error tuple.

  ## Parameters
    - `result` - A StartResult struct or error tuple

  ## Returns
    - List of `{child_id, error_reason}` tuples for StartResult structs
    - `{:error, reason}` for error tuples

  ## Examples
      iex> result = %ProcessHub.StartResult{errors: [{"child1", :timeout}]}
      iex> ProcessHub.StartResult.errors(result)
      [{"child1", :timeout}]
  """
  @spec errors(t() | error_input()) :: [{ProcessHub.child_id(), term()}] | error_input()
  def errors(%__MODULE__{errors: errors}), do: errors
  def errors({:error, reason}), do: {:error, reason}

  @doc """
  Extracts the status from a StartResult struct or error tuple.

  ## Parameters
    - `result` - A StartResult struct or error tuple

  ## Returns
    - `:ok` or `:error` for StartResult structs
    - `{:error, reason}` for error tuples

  ## Examples
      iex> result = %ProcessHub.StartResult{status: :ok}
      iex> ProcessHub.StartResult.status(result)
      :ok
  """
  @spec status(t() | error_input()) :: :ok | :error | error_input()
  def status(%__MODULE__{status: status}), do: status
  def status({:error, reason}), do: {:error, reason}

  @doc """
  Returns the first PID from the first started child process.

  ## Parameters
    - `result` - A StartResult struct

  ## Returns
    - `pid()` if processes were started
    - `nil` if no processes were started

  ## Examples
      iex> result = %ProcessHub.StartResult{started: [{"child1", [{:node1, pid}]}]}
      iex> ProcessHub.StartResult.pid(result)
      pid
  """
  @spec pid(t()) :: pid() | nil
  def pid(%__MODULE__{started: started}) do
    case List.first(started) do
      nil ->
        nil

      first_item ->
        first_item
        |> elem(1)
        |> List.first()
        |> elem(1)
    end
  end

  @doc """
  Returns all PIDs from all started child processes.

  ## Parameters
    - `result` - A StartResult struct

  ## Returns
    - List of PIDs from all started processes

  ## Examples
      iex> result = %ProcessHub.StartResult{started: [{"child1", [{:node1, pid1}, {:node2, pid2}]}]}
      iex> ProcessHub.StartResult.pids(result)
      [pid1, pid2]
  """
  @spec pids(t()) :: [pid()]
  def pids(%__MODULE__{started: started}) do
    started
    |> Enum.flat_map(fn {_, node_pids} -> node_pids end)
    |> Enum.map(fn {_node, pid} -> pid end)
  end

  @doc """
  Returns the first node from the first started child process.

  ## Parameters
    - `result` - A StartResult struct

  ## Returns
    - `node()` if processes were started
    - `nil` if no processes were started

  ## Examples
      iex> result = %ProcessHub.StartResult{started: [{"child1", [{:node1, pid}]}]}
      iex> ProcessHub.StartResult.node(result)
      :node1
  """
  @spec node(t()) :: node() | nil
  def node(%__MODULE__{started: started}) do
    case List.first(started) do
      nil ->
        nil

      first_item ->
        first_item
        |> elem(1)
        |> List.first()
        |> elem(0)
    end
  end

  @doc """
  Returns all unique nodes where child processes were started.

  ## Parameters
    - `result` - A StartResult struct

  ## Returns
    - List of unique nodes

  ## Examples
      iex> result = %ProcessHub.StartResult{started: [{"child1", [{:node1, pid1}, {:node2, pid2}]}]}
      iex> ProcessHub.StartResult.nodes(result)
      [:node1, :node2]
  """
  @spec nodes(t()) :: [node()]
  def nodes(%__MODULE__{started: started}) do
    started
    |> Enum.flat_map(fn {_, node_pids} -> node_pids end)
    |> Enum.map(fn {node, _pid} -> node end)
    |> Enum.uniq()
  end

  @doc """
  Returns the first started child entry.

  ## Parameters
    - `result` - A StartResult struct

  ## Returns
    - `{child_id, node_pids}` tuple if processes were started
    - `nil` if no processes were started

  ## Examples
      iex> result = %ProcessHub.StartResult{started: [{"child1", [{:node1, pid}]}]}
      iex> ProcessHub.StartResult.first(result)
      {"child1", [{:node1, pid}]}
  """
  @spec first(t()) :: {ProcessHub.child_id(), [{node(), pid()}]} | nil
  def first(%__MODULE__{started: started}) do
    List.first(started)
  end

  @doc """
  Returns all child IDs from started processes.

  ## Parameters
    - `result` - A StartResult struct

  ## Returns
    - List of child IDs

  ## Examples
      iex> result = %ProcessHub.StartResult{started: [{"child1", [...]}, {"child2", [...]}]}
      iex> ProcessHub.StartResult.cids(result)
      ["child1", "child2"]
  """
  @spec cids(t()) :: [ProcessHub.child_id()]
  def cids(%__MODULE__{started: started}) do
    started
    |> Enum.map(fn {cid, _node_pids} -> cid end)
  end
end
