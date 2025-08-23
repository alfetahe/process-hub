defmodule ProcessHub.Future do
  @type t :: %__MODULE__{
          promise_resolver: pid(),
          ref: reference(),
          timeout: non_neg_integer()
        }
  defstruct [:promise_resolver, :ref, :timeout]

  def await(promise) do
    ref = promise.ref

    Process.send(promise.promise_resolver, {:process_hub, :collect_results, self(), ref}, [])

    receive do
      {:process_hub, :async_results, ^ref, results} ->
        results
    after
      promise.timeout ->
        {:error, :timeout}
    end
  end
end
