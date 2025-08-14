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
