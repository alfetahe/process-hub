defmodule ProcessHub.StartResult do
  @type t() :: %__MODULE__{
          status: :ok | :error,
          started: [{ProcessHub.child_id(), [{node(), pid()}]}],
          errors: [{ProcessHub.child_id(), term()}],
          rollback: boolean()
        }
  defstruct [:status, :started, :errors, :rollback]

  def format(%__MODULE__{status: :error, errors: e, started: s, rollback: true}),
    do: {:error, {e, s}, :rollback}

  def format(%__MODULE__{status: :error, errors: e, started: s}), do: {:error, {e, s}}
  def format(%__MODULE__{status: :ok, started: s}), do: {:ok, s}
  def format({:error, reason}), do: {:error, reason}

  def errors(%__MODULE__{errors: errors}), do: errors
  def errors({:error, reason}), do: {:error, reason}

  def status(%__MODULE__{status: status}), do: status
  def status({:error, reason}), do: {:error, reason}
end
