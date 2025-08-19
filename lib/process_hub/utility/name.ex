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

  # TODO: add tests and docs.
  def system_registry(hub_id) do
    :"hub.#{hub_id}.system_registry"
  end

  @doc "Returns the worker queue identifier."
  @spec worker_queue(ProcessHub.hub_id()) :: atom()
  def worker_queue(hub_id) do
    {:via, Registry, {system_registry(hub_id), "worker_queue"}}
  end

  @doc "The name of the main initializer process."
  @spec initializer(ProcessHub.hub_id()) :: atom()
  def initializer(hub_id) do
    {:via, Registry, {system_registry(hub_id), "initializer"}}
  end

  @doc "The name of the event queue process."
  @spec event_queue(ProcessHub.hub_id()) :: atom()
  def event_queue(hub_id) do
    :"hub.#{hub_id}.event_queue"
  end

  # TODO: update tests and docs
  @doc "The name distributed supervisor process."
  def distributed_supervisor(hub_id) do
    {:via, Registry, {system_registry(hub_id), "dist_sup"}}
  end

  # TODO: update tests and docs
  @doc "The name of the task supervisor process."
  def task_supervisor(hub_id) do
    {:via, Registry, {system_registry(hub_id), "task_sup"}}
  end

  @doc "The name of the janitor process."
  @spec janitor(ProcessHub.hub_id()) :: atom()
  def janitor(hub_id) do
    {:via, Registry, {system_registry(hub_id), "janitor"}}
  end
end
