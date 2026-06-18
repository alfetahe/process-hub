defmodule Test.Helper.LoggerFilters do
  @moduledoc false
  # Test-only :logger primary filter that drops known-benign log noise so real
  # warnings stay visible. Add new entries to @noise as more come up.

  @id :drop_benign_log_noise

  # Substrings matched against the rendered message. Each is benign noise that
  # tests provoke by design and that carries no diagnostic value.
  @noise [
    # OTP ':global' disconnects a peer on every cluster churn in multinode tests.
    "overlapping partitions"
  ]

  @doc """
  Installs the primary `:logger` filter on the current node (idempotent).
  """
  @spec install() :: :ok
  def install() do
    :logger.add_primary_filter(@id, {&__MODULE__.drop_noise/2, @noise})
    :ok
  rescue
    # add_primary_filter raises if the id already exists; that is fine.
    _ -> :ok
  end

  @spec drop_noise(:logger.log_event(), [String.t()]) :: :stop | :ignore
  def drop_noise(%{msg: msg}, noise) do
    case render(msg) do
      nil -> :ignore
      text -> if Enum.any?(noise, &String.contains?(text, &1)), do: :stop, else: :ignore
    end
  end

  defp render({:string, chardata}), do: safe_string(chardata)

  defp render({format, args})
       when (is_list(format) or is_binary(format)) and is_list(args) do
    safe_string(:io_lib.format(format, args))
  rescue
    _ -> nil
  end

  defp render(_), do: nil

  defp safe_string(chardata), do: IO.chardata_to_string(chardata)
end
