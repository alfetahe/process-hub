defmodule ProcessHub.Service.Mailbox do
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Handler.ChildrenAdd.PostStartData

  @moduledoc """
  The messenger service provides API functions for receiving messages from other processes.
  """

  @doc """
  Waits for multiple child process startup results.
  """
  @spec collect_start_results(ProcessHub.hub_id(), function(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def collect_start_results(hub_id, handler, opts) do
    collect_from = Keyword.get(opts, :collect_from, Cluster.nodes(hub_id, [:include_local]))

    nodes_results =
      Enum.map(collect_from, fn node ->
        {node,
         receive do
           {:collect_start_results, start_results, ^node} ->
             Enum.map(start_results, fn %PostStartData{result: result, cid: cid} ->
               {cid, handler.(nil, result, node)}
             end)
         after
           # TODO: Make sure returning error from here does not affect the caller.
           Keyword.get(opts, :timeout) ->
             {:error, "failed to receive startup results from #{node}"}
         end}
      end)

    start_results =
      Enum.reduce(nodes_results, %{}, fn
        {_node, results}, acc ->
          Enum.reduce(results, acc, fn {cid, result}, acc ->
            Map.put(acc, cid, Map.get(acc, cid, []) ++ [result])
          end)
      end)

    errors =
      Enum.any?(start_results, fn {_cid, results} ->
        Enum.any?(results, fn result ->
          !is_pid(result)
        end)
      end)

    startup_responses = extract_first(start_results, opts)

    case errors do
      true -> {:ok, startup_responses}
      false -> {:error, startup_responses}
    end
  end

  @doc """
  Waits for multiple child process termination results.
  """
  @spec collect_stop_results(ProcessHub.hub_id(), function(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def collect_stop_results(hub_id, handler, opts) do
    collect_from = Keyword.get(opts, :collect_from, Cluster.nodes(hub_id, [:include_local]))

    nodes_results =
      Enum.map(collect_from, fn node ->
        {node,
         receive do
           {:collect_stop_results, stop_results, ^node} ->
             Enum.map(stop_results, fn {cid, result, _node} ->
               {cid, handler.(nil, result, node)}
             end)
         after
           # TODO: Make sure returning error from here does not affect the caller.
           Keyword.get(opts, :timeout) ->
             {:error, "failed to receive stop results from #{node}"}
         end}
      end)

    stop_results =
      Enum.reduce(nodes_results, %{}, fn
        {_node, results}, acc ->
          Enum.reduce(results, acc, fn {cid, result}, acc ->
            Map.put(acc, cid, Map.get(acc, cid, []) ++ [result])
          end)
      end)

    errors =
      Enum.all?(stop_results, fn {_node, child_responses} ->
        Enum.all?(child_responses, fn resp ->
          is_atom(resp)
        end)
      end)

    stop_responses = extract_first(stop_results, opts)

    case errors do
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
    |> List.foldl(%{}, fn {child_id, responses}, acc ->
      Map.put(acc, child_id, Map.get(acc, child_id, []) ++ [responses])
    end)
    |> Map.to_list()
  end

  @doc "Receives a single child response message."
  def receive_response(type, child_id, node, handler, timeout, error \\ nil) do
    receive do
      {^type, ^child_id, resp, receive_node} -> {child_id, handler.(child_id, resp, receive_node)}
    after
      timeout -> {child_id, {:error, {node, error}}}
    end
  end

  @doc "Receives a single child response message."
  def receive_response(type, handler, timeout) do
    receive do
      {^type, child_id, resp, receive_node} -> {child_id, handler.(child_id, resp, receive_node)}
    after
      timeout -> {:error, :receive_timeout}
    end
  end

  defp extract_first(results, opts) do
    case Keyword.get(opts, :return_first, false) do
      false -> results
      true -> List.first(results)
    end
  end
end
