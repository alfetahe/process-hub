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

  @doc "The name of the hook registry process."
  @spec hook_registry(ProcessHub.hub_id()) :: atom()
  def hook_registry(hub_id) do
    :"hub.#{hub_id}.hook_registry"
  end

  @doc "The name of the main initializer process."
  @spec initializer(ProcessHub.hub_id()) :: atom()
  def initializer(hub_id) do
    {:via, Registry, {system_registry(hub_id), "initializer"}}
  end
end
