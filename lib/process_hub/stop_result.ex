defmodule ProcessHub.StopResult do
  @moduledoc """
  A struct representing the result of stopping child processes across multiple nodes.

  This module provides utilities for formatting and extracting information from
  stop operation results, including successful stops and errors.
  """

  @type t() :: %__MODULE__{
          status: :ok | :error,
          stopped: [{ProcessHub.child_id(), [node()]}],
          errors: [{ProcessHub.child_id(), term()}]
        }

  @type error_input :: {:error, term()}

  defstruct [:status, :stopped, :errors]

  @doc """
  Formats a StopResult struct into a standardized tuple format.

  ## Parameters
    - `result` - A StopResult struct or error tuple

  ## Returns
    - `{:ok, stopped}` for successful operations
    - `{:error, {errors, stopped}}` for failed operations
    - `{:error, reason}` for error tuples

  ## Examples
      iex> result = %ProcessHub.StopResult{status: :ok, stopped: [{"child1", [:node1]}]}
      iex> ProcessHub.StopResult.format(result)
      {:ok, [{"child1", [:node1]}]}

      iex> ProcessHub.StopResult.format({:error, :timeout})
      {:error, :timeout}
  """
  @spec format(t() | error_input()) ::
          {:ok, term()}
          | {:error, {term(), term()}}
          | {:error, term()}
  def format(%__MODULE__{status: :error, errors: e, stopped: s}), do: {:error, {e, s}}
  def format(%__MODULE__{status: :ok, stopped: s}), do: {:ok, s}
  def format({:error, reason}), do: {:error, reason}

  @doc """
  Extracts the errors from a StopResult struct or error tuple.

  ## Parameters
    - `result` - A StopResult struct or error tuple

  ## Returns
    - List of `{child_id, error_reason}` tuples for StopResult structs
    - `{:error, reason}` for error tuples

  ## Examples
      iex> result = %ProcessHub.StopResult{errors: [{"child1", :timeout}]}
      iex> ProcessHub.StopResult.errors(result)
      [{"child1", :timeout}]
  """
  @spec errors(t() | error_input()) :: [{ProcessHub.child_id(), term()}] | error_input()
  def errors(%__MODULE__{errors: errors}), do: errors
  def errors({:error, reason}), do: {:error, reason}

  @doc """
  Extracts the status from a StopResult struct or error tuple.

  ## Parameters
    - `result` - A StopResult struct or error tuple

  ## Returns
    - `:ok` or `:error` for StopResult structs
    - `{:error, reason}` for error tuples

  ## Examples
      iex> result = %ProcessHub.StopResult{status: :ok}
      iex> ProcessHub.StopResult.status(result)
      :ok
  """
  @spec status(t() | error_input()) :: :ok | :error | error_input()
  def status(%__MODULE__{status: status}), do: status
  def status({:error, reason}), do: {:error, reason}

  @doc """
  Returns the first stopped child entry.

  ## Parameters
    - `result` - A StopResult struct

  ## Returns
    - `{child_id, nodes}` tuple if processes were stopped
    - `nil` if no processes were stopped

  ## Examples
      iex> result = %ProcessHub.StopResult{stopped: [{"child1", [:node1]}]}
      iex> ProcessHub.StopResult.first(result)
      {"child1", [:node1]}
  """
  @spec first(t()) :: {ProcessHub.child_id(), [node()]} | nil
  def first(%__MODULE__{stopped: stopped}) do
    List.first(stopped)
  end

  @doc """
  Returns all child IDs from stopped processes.

  ## Parameters
    - `result` - A StopResult struct

  ## Returns
    - List of child IDs

  ## Examples
      iex> result = %ProcessHub.StopResult{stopped: [{"child1", [...]}, {"child2", [...]}]}
      iex> ProcessHub.StopResult.cids(result)
      ["child1", "child2"]
  """
  @spec cids(t()) :: [ProcessHub.child_id()]
  def cids(%__MODULE__{stopped: stopped}) do
    stopped
    |> Enum.map(fn {cid, _nodes} -> cid end)
  end

  @doc """
  Returns all unique nodes where child processes were stopped.

  ## Parameters
    - `result` - A StopResult struct

  ## Returns
    - List of unique nodes

  ## Examples
      iex> result = %ProcessHub.StopResult{stopped: [{"child1", [:node1, :node2]}]}
      iex> ProcessHub.StopResult.nodes(result)
      [:node1, :node2]
  """
  @spec nodes(t()) :: [node()]
  def nodes(%__MODULE__{stopped: stopped}) do
    stopped
    |> Enum.flat_map(fn {_, nodes} -> nodes end)
    |> Enum.uniq()
  end
end
