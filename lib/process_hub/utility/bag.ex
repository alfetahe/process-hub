defmodule ProcessHub.Utility.Bag do
  @moduledoc """
  Utility functions for testing.
  """

  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook

  @default_timeout 5000

  @doc """
  Sends hook messages to the given process.
  """
  @spec hook_erlang_send(term(), atom() | pid() | port() | reference() | {atom(), node()}, any()) ::
          any()
  def hook_erlang_send(hook_data, pid, msg) do
    :erlang.send(pid, {msg, hook_data})
  end

  @doc """
  Returns the current timestamp in the given precision.
  """
  @spec timestamp(:microsecond | :millisecond | :nanosecond | :second | pos_integer()) ::
          integer()
  def timestamp(precision \\ :second) do
    DateTime.utc_now() |> DateTime.to_unix(precision)
  end

  @doc """
  Retrieves the value associated with a key from a list of key-value tuples.

  This function searches through a list of `{key, value}` tuples and returns the value
  associated with the first matching key. If no matching key is found, the default
  value is returned.

  ## Parameters
  - `list` - A list of `{key, value}` tuples to search through
  - `key` - The key to search for
  - `default` - The value to return if the key is not found (default: `nil`)

  ## Examples
      iex> ProcessHub.Utility.Bag.get_by_key([{:a, 1}, {:b, 2}, {:c, 3}], :b)
      2

      iex> ProcessHub.Utility.Bag.get_by_key([{:a, 1}, {:b, 2}], :c, :not_found)
      :not_found

      iex> ProcessHub.Utility.Bag.get_by_key([], :any_key, "default")
      "default"

      iex> ProcessHub.Utility.Bag.get_by_key([{"key1", "value1"}, {"key2", "value2"}], "key1")
      "value1"

  ## Notes
  - Only searches for exact key matches using strict equality (`===`)
  - Returns the value from the first matching tuple found
  - Works with any key/value types (atoms, strings, integers, etc.)
  - Gracefully ignores non-tuple elements in the list
  - Only considers tuples with at least 2 elements (key-value pairs)
  """
  @spec get_by_key([{any(), any()}], any(), any()) :: any()
  def get_by_key(list, key, default \\ nil) do
    result =
      Enum.find(list, default, fn
        {k, _v} -> k === key
        _ -> false
      end)

    case result do
      {^key, v} -> v
      _ -> default
    end
  end

  @doc """
  Waits and receives multiple messages.
  """
  @spec receive_multiple(pos_integer(), term(), Keyword.t()) :: any()
  def receive_multiple(x, receive_key, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    error_msg = Keyword.get(opts, :error_msg, "")

    for y <- 1..x//1 do
      case receive_key do
        {key1, key2} ->
          receive do
            {^key1, data} ->
              {:ok, data}

            {^key2, data} ->
              {:ok, data}
          after
            timeout -> raise("failed iteration: #{y}.#{error_msg}")
          end

        _ ->
          receive do
            {^receive_key, data} ->
              {:ok, data}
          after
            timeout -> raise("failed iteration: #{y}.#{error_msg}")
          end
      end
    end
  end

  @doc """
  Awaits cluster join events for the specified nodes.

  Automatically calculates the expected message count based on:
  - Number of nodes joining
  - Current cluster size before join
  - Hook scope (:global or :local)

  ## Parameters
  - `joining_nodes` - List of nodes that are joining (or count as integer)
  - `opts` - Options:
    - `:cluster_size` - Current cluster size before join (required for :global scope)
    - `:scope` - :local (default) or :global
    - `:timeout` - Per-message timeout (default: 10000ms)

  ## Examples

      # Local scope - one message per joining node
      Bag.await_cluster_join(peer_names, scope: :local)

      # Global scope - messages from all nodes in cluster
      Bag.await_cluster_join(peer_names, scope: :global, cluster_size: 5)
  """
  @spec await_cluster_join([node()] | pos_integer(), Keyword.t()) :: list()
  def await_cluster_join(joining_nodes, opts \\ [])

  def await_cluster_join(joining_count, opts) when is_integer(joining_count) do
    scope = Keyword.get(opts, :scope, :local)
    cluster_size = Keyword.get(opts, :cluster_size, 1)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    count = calculate_join_message_count(joining_count, cluster_size, scope)

    if count > 0 do
      receive_multiple(count, Hook.post_node_join(), timeout: timeout)
    else
      []
    end
  end

  def await_cluster_join(joining_nodes, opts) when is_list(joining_nodes) do
    await_cluster_join(length(joining_nodes), opts)
  end

  @doc """
  Awaits cluster leave events for the specified nodes.

  Automatically calculates the expected message count based on:
  - Number of nodes leaving
  - Current cluster size before leave
  - Hook scope (:global or :local)

  ## Parameters
  - `leaving_nodes` - List of nodes that are leaving (or count as integer)
  - `opts` - Options:
    - `:cluster_size` - Current cluster size BEFORE leave (required for :global scope)
    - `:scope` - :local (default) or :global
    - `:timeout` - Per-message timeout (default: 10000ms)
  """
  @spec await_cluster_leave([node()] | pos_integer(), Keyword.t()) :: list()
  def await_cluster_leave(leaving_nodes, opts \\ [])

  def await_cluster_leave(leaving_count, opts) when is_integer(leaving_count) do
    scope = Keyword.get(opts, :scope, :local)
    cluster_size = Keyword.get(opts, :cluster_size, 1)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    count = calculate_leave_message_count(leaving_count, cluster_size, scope)

    if count > 0 do
      receive_multiple(count, Hook.post_node_leave(), timeout: timeout)
    else
      []
    end
  end

  def await_cluster_leave(leaving_nodes, opts) when is_list(leaving_nodes) do
    await_cluster_leave(length(leaving_nodes), opts)
  end

  # Formula: joining_count * (cluster_size_before + joining_count)
  # Each node in the final cluster fires post_cluster_join for each new node
  defp calculate_join_message_count(joining_count, cluster_size_before, :global) do
    cluster_size_after = cluster_size_before + joining_count
    joining_count * cluster_size_after
  end

  defp calculate_join_message_count(joining_count, _cluster_size, :local) do
    joining_count
  end

  # Formula: leaving_count * (cluster_size_before - leaving_count)
  # Each remaining node fires post_cluster_leave for each removed node
  defp calculate_leave_message_count(leaving_count, cluster_size_before, :global) do
    cluster_size_after = max(0, cluster_size_before - leaving_count)
    leaving_count * cluster_size_after
  end

  defp calculate_leave_message_count(leaving_count, _cluster_size, :local) do
    leaving_count
  end

  @type gen_child_specs_opts :: [{:prefix, String.t()} | {:id_type, :string | :atom}]

  @doc """
  Generates child specs for testing.
  """
  @spec gen_child_specs(integer, gen_child_specs_opts()) :: list
  def gen_child_specs(count, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "child")
    id_type = Keyword.get(opts, :id_type, :string)

    for x <- 1..count do
      id =
        (prefix <> Integer.to_string(x))
        |> then(fn string_id ->
          case id_type do
            :string -> string_id
            :atom -> String.to_atom(string_id)
          end
        end)

      %{id: id, start: {Test.Helper.TestServer, :start_link, [%{name: id}]}}
    end
  end

  @doc """
  Returns all messages in the mailbox.
  """
  @spec all_messages :: [term()]
  def all_messages() do
    all_messages([])
  end

  @doc """
  Generates a hook manager for receiving messages.
  """
  @spec recv_hook(atom(), pid()) :: HookManager.t()
  def recv_hook(key, recv_pid) do
    %HookManager{
      id: key,
      m: ProcessHub.Utility.Bag,
      f: :hook_erlang_send,
      a: [:_, recv_pid, key]
    }
  end

  defp all_messages(messages) do
    receive do
      msg -> all_messages([msg | messages])
    after
      0 -> messages |> Enum.reverse()
    end
  end

  @doc """
  Receives messages until a reducer callback signals completion.

  The reducer function receives `(accumulator, message_data)` and returns:
  - `{:cont, new_acc}` - Continue waiting for more messages
  - `{:halt, result}` - Stop and return the result

  ## Parameters
  - `receive_key` - The message key to match (atom or {key1, key2} tuple)
  - `initial_acc` - Initial accumulator value
  - `reducer` - Function `(acc, msg_data) -> {:cont, new_acc} | {:halt, result}`
  - `opts` - Options:
    - `:timeout` - Per-message timeout (default: 10000ms)
    - `:error_msg` - Custom error message on timeout

  ## Examples

      # Wait until all expected child_ids are received
      expected_ids = MapSet.new(child_ids)
      Bag.receive_until(Hook.handover_delivered(), expected_ids, fn acc, %{child_ids: ids} ->
        remaining = MapSet.difference(acc, MapSet.new(ids))
        if MapSet.size(remaining) == 0 do
          {:halt, :all_received}
        else
          {:cont, remaining}
        end
      end)

      # Collect all messages until a specific count
      Bag.receive_until(:my_hook, [], fn acc, data ->
        new_acc = [data | acc]
        if length(new_acc) >= 10, do: {:halt, new_acc}, else: {:cont, new_acc}
      end)
  """
  @spec receive_until(
          term(),
          term(),
          (term(), term() -> {:cont, term()} | {:halt, term()}),
          Keyword.t()
        ) :: term()
  def receive_until(receive_key, initial_acc, reducer, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    error_msg = Keyword.get(opts, :error_msg, "receive_until timeout")

    do_receive_until(receive_key, initial_acc, reducer, timeout, error_msg)
  end

  defp do_receive_until(receive_key, acc, reducer, timeout, error_msg) do
    case receive_key do
      {key1, key2} ->
        receive do
          {^key1, data} ->
            handle_reducer_result(receive_key, reducer.(acc, data), reducer, timeout, error_msg)

          {^key2, data} ->
            handle_reducer_result(receive_key, reducer.(acc, data), reducer, timeout, error_msg)
        after
          timeout -> raise(error_msg)
        end

      _ ->
        receive do
          {^receive_key, data} ->
            handle_reducer_result(receive_key, reducer.(acc, data), reducer, timeout, error_msg)
        after
          timeout -> raise(error_msg)
        end
    end
  end

  defp handle_reducer_result(_receive_key, {:halt, result}, _reducer, _timeout, _error_msg),
    do: result

  defp handle_reducer_result(receive_key, {:cont, new_acc}, reducer, timeout, error_msg) do
    do_receive_until(receive_key, new_acc, reducer, timeout, error_msg)
  end

  @doc """
  Awaits messages until all expected child_ids have been received.

  Useful for hooks like `handover_delivered` that send `%{child_ids: [...]}`.

  ## Parameters
  - `receive_key` - The message key to match
  - `expected_child_ids` - List of child_ids to wait for
  - `opts` - Options:
    - `:timeout` - Per-message timeout (default: 10000ms)
    - `:error_msg` - Custom error message on timeout
    - `:child_ids_key` - Key to extract child_ids from message (default: `:child_ids`)

  ## Returns
  List of all received message data.

  ## Example

      Bag.await_child_ids(Hook.handover_delivered(), migrated_child_ids, timeout: 60_000)
  """
  @spec await_child_ids(term(), [term()], Keyword.t()) :: [map()]
  def await_child_ids(receive_key, expected_child_ids, opts \\ []) do
    child_ids_key = Keyword.get(opts, :child_ids_key, :child_ids)
    error_msg = Keyword.get(opts, :error_msg, "await_child_ids timeout")
    opts = Keyword.put(opts, :error_msg, error_msg)

    initial_acc = %{
      remaining: MapSet.new(expected_child_ids),
      received: []
    }

    result =
      receive_until(
        receive_key,
        initial_acc,
        fn acc, data ->
          ids_in_msg = Map.get(data, child_ids_key, [])
          new_remaining = MapSet.difference(acc.remaining, MapSet.new(ids_in_msg))
          new_acc = %{acc | remaining: new_remaining, received: [data | acc.received]}

          if MapSet.size(new_remaining) == 0 do
            {:halt, new_acc}
          else
            {:cont, new_acc}
          end
        end,
        opts
      )

    Enum.reverse(result.received)
  end
end
