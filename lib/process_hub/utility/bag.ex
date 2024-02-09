defmodule ProcessHub.Utility.Bag do
  @moduledoc """
  Utility functions.
  """

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

  @doc """
  Generates child specs for testing.
  """
  @spec gen_child_specs(integer, any) :: list
  def gen_child_specs(count, prefix \\ "child") do
    for x <- 1..count do
      id = (prefix <> Integer.to_string(x)) |> String.to_atom()

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

  defp all_messages(messages) do
    receive do
      msg -> all_messages([msg | messages])
    after
      0 -> messages |> Enum.reverse()
    end
  end
end
