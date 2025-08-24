defmodule ProcessHub.StopResult do
  @type t() :: %__MODULE__{
          status: :ok | :error,
          stopped: [{ProcessHub.child_id(), [node()]}],
          errors: [{ProcessHub.child_id(), term()}]
        }
  defstruct [:status, :stopped, :errors]

  def format(%__MODULE__{status: :error, errors: e, stopped: s}), do: {:error, {e, s}}
  def format(%__MODULE__{status: :ok, stopped: s}), do: {:ok, s}
  def format({:error, reason}), do: {:error, reason}
end
