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

  def errors(%__MODULE__{errors: errors}), do: errors
  def errors({:error, reason}), do: {:error, reason}

  def status(%__MODULE__{status: status}), do: status
  def status({:error, reason}), do: {:error, reason}

  def first(%__MODULE__{stopped: stopped}) do
    List.first(stopped)
  end

  def cids(%__MODULE__{stopped: stopped}) do
    stopped
    |> Enum.map(fn {cid, _nodes} -> cid end)
  end

  def nodes(%__MODULE__{stopped: stopped}) do
    stopped
    |> Enum.flat_map(fn {_, nodes} -> nodes end)
    |> Enum.uniq()
  end
end
