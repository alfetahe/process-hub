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
    @spec handle_migration(
            struct(),
            ProcessHub.hub_id(),
            [ProcessHub.child_spec()],
            node(),
            term()
          ) ::
            :ok
    def handle_migration(_struct, hub_id, child_specs, added_node, sync_strategy) do
      Enum.each(child_specs, fn child_spec ->
        Distributor.child_terminate(hub_id, child_spec.id, sync_strategy)
      end)

      Distributor.children_redist_init(hub_id, child_specs, added_node, [])

      HookManager.dispatch_hook(hub_id, Hook.children_migrated(), {added_node, child_specs})

      :ok
    end
  end
end
