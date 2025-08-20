defmodule ProcessHub.Utility.Name do
  @moduledoc """
  Utility functions for generating names processes/ETS tables registered under
  the `hub_id`.
  """

  @doc "Returns the localstorage identifier."
  @spec misc_storage(ProcessHub.hub_id()) :: atom()
  def misc_storage(hub_id) do
    :"hub.#{hub_id}.misc_storage"
  end
end
