defmodule ProcessHub.Service.Mailbox do
  alias ProcessHub.Service.Cluster

  @moduledoc """
  The messenger service provides API functions for receiving messages from other processes.
  """

  @doc """
  Waits for multiple child process startup results.
  """
  @spec collect_start_results(ProcessHub.hub_id(), keyword()) ::
          {:ok, list()} | {:error, {list(), list()}}
  def collect_start_results(hub_id, opts) do
    result_handler =
      Keyword.get(opts, :result_handler, fn _cid, _node, result ->
        case result do
          {:ok, pid} -> {:ok, pid}
          err -> err
        end
      end)

    opts = Keyword.put(opts, :receive_key, :collect_start_results)

    collect_transition_results(hub_id, result_handler, opts)
  end

  @doc """
  Waits for multiple child process termination results.
  """
  @spec collect_stop_results(ProcessHub.hub_id(), keyword()) ::
          {:ok, list()} | {:error, {list(), list()}}
  def collect_stop_results(hub_id, opts) do
    result_handler =
      Keyword.get(opts, :result_handler, fn _child_id, _node, resp ->
        case resp do
          :ok -> :ok
          error -> error
        end
      end)

    opts = Keyword.put(opts, :receive_key, :collect_stop_results)

    collect_transition_results(hub_id, result_handler, opts)
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

  defp collect_transition_results(hub_id, result_handler, opts) do
    timeout = Keyword.get(opts, :timeout)
    recv_key = Keyword.get(opts, :receive_key)
    collect_from = Keyword.get(opts, :collect_from, Cluster.nodes(hub_id, [:include_local]))
    required_cids = Keyword.get(opts, :required_cids, [])

    {success_results, errors} =
      recursive_collect(
        {[], []},
        collect_from,
        recv_key,
        result_handler,
        timeout,
        required_cids
      )

    success_results = filter_transition_result(success_results, opts)

    case length(errors) > 0 do
      false ->
        {:ok, success_results}

      true ->
        {:error, {filter_transition_result(errors, opts), success_results}}
    end
  end

  # Get the first result if the return_first option is set to true.
  # This is used for single child process operations.
  defp filter_transition_result(results, opts) do
    case Keyword.get(opts, :return_first, false) do
      false -> results
      true -> List.first(results) || []
    end
  end

  defp recursive_collect({s, r}, collect_from, recv_key, result_handler, timeout, required_cids) do
    {status, _, success_results, errors} =
      Enum.reduce(1..length(collect_from), {:continue, collect_from, [], []}, fn
        _, {:continue, cf, nres, errors} ->
          handle_continue_recv(cf, nres, errors, timeout, recv_key, result_handler)

        _, {:err, cf, nres, errors} ->
          handle_err_recv(cf, nres, errors)
      end)

    # When starting a child, we have have to wait for the response from another node.
    # This occurs when the child is started on a different node due to forwarding.
    # In such cases, we need to wait for the response from the node where the child was started.
    # By defining required_cids, we can wait for the response from the node where the child was started.
    required_cids =
      Enum.filter(required_cids, fn cid ->
        List.keyfind(success_results, cid, 0, nil) === nil &&
          List.keyfind(errors, cid, 0, nil) === nil
      end)

    results = {success_results ++ s, errors ++ r}

    case length(required_cids) > 0 && status !== :err do
      false ->
        results

      true ->
        recursive_collect(results, collect_from, recv_key, result_handler, timeout, required_cids)
    end
  end

  defp handle_continue_recv(collect_from, sresults, errors, timeout, recv_key, res_handler) do
    receive do
      {^recv_key, recv_results, node} ->
        collect_from = Enum.reject(collect_from, fn n -> n == node end)

        {success_results, errors} =
          Enum.reduce(
            recv_results,
            {sresults, errors},
            fn {cid, result}, {sres, errs} ->
              handle_collect_result(cid, node, result, sres, errs, res_handler)
            end
          )

        {:continue, collect_from, success_results, errors}
    after
      timeout ->
        handle_err_recv(collect_from, sresults, errors)
    end
  end

  defp handle_err_recv(unhandled_nodes, nodes_result, errors) do
    [err_node | unhandled_nodes] = unhandled_nodes

    errors = [{:undefined, err_node, :node_receive_timeout} | errors]

    {:err, unhandled_nodes, nodes_result, errors}
  end

  defp handle_collect_result(cid, node, result, success_results, errors, result_handler) do
    case result_handler.(cid, node, result) do
      {:ok, res} ->
        updated_succ_results =
          case List.keyfind(success_results, cid, 0, nil) do
            nil ->
              [{cid, [{node, res}]} | success_results]

            existing_results ->
              List.keyreplace(success_results, cid, 0, {cid, [{node, res} | existing_results]})
          end

        {updated_succ_results, errors}

      :ok ->
        updated_succ_results =
          case List.keyfind(success_results, cid, 0, nil) do
            nil ->
              [{cid, [node]} | success_results]

            existing_results ->
              List.keyreplace(success_results, cid, 0, {cid, [node | existing_results]})
          end

        {updated_succ_results, errors}

      {:error, err} ->
        {success_results, [{cid, node, err} | errors]}
    end
  end
end
