defmodule ProcessHub.Future do
  @moduledoc """
  A struct representing an asynchronous operation that can be awaited for results.

  The Future module provides functionality to handle asynchronous operations in ProcessHub,
  allowing callers to wait for results from distributed process start/stop operations.
  This is particularly useful when you need to verify the outcome of operations.
  """

  @type t :: %__MODULE__{
          future_resolver: pid(),
          ref: reference(),
          timeout: non_neg_integer()
        }

  @type future_input :: t() | {:ok, t()} | {:error, term()} | term()
  @type await_result :: ProcessHub.StartResult.t() | ProcessHub.StopResult.t() | {:error, term()}

  defstruct [:future_resolver, :ref, :timeout]

  @doc """
  Waits for the completion of an asynchronous operation and returns the results.

  This function blocks the calling process until the future resolves or times out.
  It communicates with the future resolver process to collect the final results
  of the distributed operation.

  Handles multiple input types:
  - `Future.t()` struct - Awaits the future operation
  - `{:ok, Future.t()}` - Extracts and awaits the future
  - `{:error, term()}` - Returns the error unchanged
  - Other input - Returns `{:error, :invalid_argument}`

  ## Parameters
    - `future` - A Future struct, `{:ok, Future.t()}` tuple, `{:error, term()}` tuple, or other input

  ## Returns
    - `ProcessHub.StartResult.t()` for start operations
    - `ProcessHub.StopResult.t()` for stop operations
    - `{:error, :timeout}` if the operation times out
    - `{:error, :invalid_argument}` for invalid input
    - `{:error, reason}` for error tuples
  """
  @spec await(future_input()) :: await_result()
  def await(future) when is_struct(future) do
    ref = future.ref

    Process.send(future.future_resolver, {:process_hub, :collect_results, self(), ref}, [])

    receive do
      {:process_hub, :async_results, ^ref, results} ->
        results
    after
      future.timeout + 1000 ->
        {:error, :timeout}
    end
  end

  def await({:ok, future}) when is_struct(future) do
    await(future)
  end

  def await({:error, msg}), do: {:error, msg}

  def await(_), do: {:error, :invalid_argument}
end
