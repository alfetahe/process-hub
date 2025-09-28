defmodule ProcessHub.Utility.Bag do
  @moduledoc """
  Utility functions for testing.
  """

  alias ProcessHub.Service.HookManager

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
    result = Enum.find(list, default, fn
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

    for y <- 1..x do
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
end
