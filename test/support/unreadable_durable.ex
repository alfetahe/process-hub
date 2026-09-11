defmodule Test.Support.UnreadableDurable do
  @moduledoc """
  The `{:durable_ets, _}` backend with a durable medium that cannot be read back:
  every callback is `ProcessHub.Service.Storage.DurableEts`'s except
  `read_durable/1`, which answers an error.
  """

  alias ProcessHub.Service.Storage.DurableEts

  for {name, arity} <- DurableEts.__info__(:functions), name != :read_durable do
    args = Macro.generate_arguments(arity, __MODULE__)
    defdelegate unquote(name)(unquote_splicing(args)), to: DurableEts
  end

  def read_durable(_ref), do: {:error, :unreadable}
end
