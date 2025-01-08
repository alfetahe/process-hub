defmodule ProcessHub.Utility.Name do
  @moduledoc """
  Utility functions for generating names processes/ETS tables registered under
  the `hub_id`.
  """

  @doc "Returns the process registry table identifier."
  @spec registry(ProcessHub.hub_id()) :: atom()
  def registry(hub_id) do
    :"hub.#{hub_id}.process_registry"
  end

  @doc "Returns the localstorage identifier."
  @spec local_storage(ProcessHub.hub_id()) :: atom()
  def local_storage(hub_id) do
    :"hub.#{hub_id}.local_storage"
  end

  @doc "Returns the worker queue identifier."
  @spec worker_queue(ProcessHub.hub_id()) :: atom()
  def worker_queue(hub_id) do
    :"hub.#{hub_id}.worker_queue"
  end

  @doc "The name of the main initializer process."
  @spec initializer(ProcessHub.hub_id()) :: atom()
  def initializer(hub_id) do
    :"hub.#{hub_id}.initializer"
  end

  @doc "The name of the event queue process."
  @spec event_queue(ProcessHub.hub_id()) :: atom()
  def event_queue(hub_id) do
    :"hub.#{hub_id}.event_queue"
  end

  @doc "The name of main coordinator process."
  @spec coordinator(ProcessHub.hub_id()) :: atom()
  def coordinator(hub_id) do
    :"hub.#{hub_id}.coordinator"
  end

  @doc "The name distributed supervisor process."
  @spec distributed_supervisor(ProcessHub.hub_id()) :: atom()
  def distributed_supervisor(hub_id) do
    :"hub.#{hub_id}.distributed_supervisor"
  end

  @doc "The name of the task supervisor process."
  @spec task_supervisor(ProcessHub.hub_id()) :: atom()
  def task_supervisor(hub_id) do
    :"hub.#{hub_id}.task_supervisor"
  end

  @doc "The name of the hook registry process."
  @spec hook_registry(ProcessHub.hub_id()) :: atom()
  def hook_registry(hub_id) do
    :"hub.#{hub_id}.hook_registry"
  end

  @doc "The name of the janitor process."
  @spec janitor(ProcessHub.hub_id()) :: atom()
  def janitor(hub_id) do
    :"hub.#{hub_id}.janitor"
  end
end
