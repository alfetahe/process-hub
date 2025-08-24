defmodule ProcessHub.Future do
  @type t :: %__MODULE__{
          future_resolver: pid(),
          ref: reference(),
          timeout: non_neg_integer()
        }
  defstruct [:future_resolver, :ref, :timeout]

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
