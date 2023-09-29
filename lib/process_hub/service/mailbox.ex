defmodule ProcessHub.Service.Mailbox do
  @moduledoc """
  The messenger service provides API functions for receiving messages from other processes.
  """

  @doc """
  Waits for multiple child process startup results.
  """
  @spec receive_start_resp([{node(), [ProcessHub.child_id()]}], keyword()) ::
          {:ok, list()} | {:error, list()}
  def receive_start_resp(receivables, opts) do
    handler = fn _child_id, resp, node ->
      case resp do
        {:ok, child_pid} -> {node, child_pid}
        error -> {node, error}
      end
    end

    startup_responses =
      receive_child_resp(
        receivables,
        :child_start_resp,
        handler,
        :child_start_timeout,
        Keyword.get(opts, :timeout)
      )

    any_errors =
      Enum.all?(startup_responses, fn {_node, child_responses} ->
        Enum.all?(child_responses, fn {_child_id, resp} ->
          is_pid(resp)
        end)
      end)

    startup_responses = extract_first(startup_responses, opts)

    case any_errors do
      true -> {:ok, startup_responses}
      false -> {:error, startup_responses}
    end
  end

  @doc """
  Waits for multiple child process termination results.
  """
  @spec receive_stop_resp([{node(), [ProcessHub.child_id()]}], keyword()) ::
          {:ok, list()} | {:error, list()}
  def receive_stop_resp(receivables, opts) do
    handler = fn _child_id, resp, node ->
      case resp do
        :ok -> node
        error -> {node, error}
      end
    end

    stop_responses =
      receive_child_resp(
        receivables,
        :child_stop_resp,
        handler,
        :child_stop_timeout,
        Keyword.get(opts, :timeout)
      )

    any_errors =
      Enum.all?(stop_responses, fn {_node, child_responses} ->
        Enum.all?(child_responses, fn resp ->
          is_atom(resp)
        end)
      end)

    stop_responses = extract_first(stop_responses, opts)

    case any_errors do
      true -> {:ok, stop_responses}
      false -> {:error, stop_responses}
    end
  end

  @doc """
  Waits for multiple child response messages.
  """
  @spec receive_child_resp(
          [{node(), [ProcessHub.child_id()]}],
          term(),
          function(),
          term(),
          pos_integer()
        ) :: list()
  def receive_child_resp(receivables, type, handler, error, timeout) do
    Enum.reduce(receivables, [], fn {node, child_ids}, acc ->
      children_responses =
        Enum.map(child_ids, fn child_id ->
          receive_response(type, child_id, node, handler, timeout, error)
        end)

      children_responses ++ acc
    end)
    |> List.foldl([], fn {child_id, responses}, acc ->
      Keyword.put(acc, child_id, [responses | Keyword.get(acc, child_id, [])])
    end)
  end

  @doc "Receives a single child response message."
  def receive_response(type, child_id, node, handler, timeout, error) do
    receive do
      {^type, ^child_id, resp, ^node} -> {child_id, handler.(child_id, resp, node)}
    after
      timeout -> {child_id, {:error, {node, error}}}
    end
  end

  defp extract_first(results, opts) do
    case Keyword.get(opts, :return_first, false) do
      false -> results
      true -> List.first(results)
    end
  end
end
