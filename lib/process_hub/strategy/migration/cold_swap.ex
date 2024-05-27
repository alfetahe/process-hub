defmodule ProcessHub.Strategy.Migration.ColdSwap do
  @moduledoc """
  The cold swap migration strategy implements the `ProcessHub.Strategy.Migration.Base` protocol.
  It provides a migration strategy where the local process is terminated before starting it on
  the remote node.

  Cold swap is a safe strategy if we want to ensure that the child process is not
  running on multiple nodes at the same time.

  This is the default strategy for process migration.
  """

  alias ProcessHub.Strategy.Migration.Base, as: MigrationStrategy
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Distributor

  @typedoc """
  The cold swap migration struct.

  This struct does not contain any configuration options.
  """
  @type t() :: %__MODULE__{}
  defstruct []

  defimpl MigrationStrategy, for: ProcessHub.Strategy.Migration.ColdSwap do
    @impl true
    def init(_strategy, _hub_id), do: nil

    @impl true
    def handle_migration(_struct, hub_id, child_specs, added_node, sync_strategy) do
      Distributor.children_terminate(hub_id, Enum.map(child_specs, & &1.id), sync_strategy)
      Distributor.children_redist_init(hub_id, added_node, child_specs, [])
      HookManager.dispatch_hook(hub_id, Hook.children_migrated(), {added_node, child_specs})

      :ok
    end

    @impl true
    def handle_process_startups(_struct, _hub_id, _pids), do: :ok
  end
end
