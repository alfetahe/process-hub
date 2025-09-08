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
    def init(strategy, _hub), do: strategy

    @impl true
    def handle_migration(_struct, hub, children_data, added_node, sync_strategy) do
      Distributor.children_terminate(
        hub,
        Enum.map(children_data, fn {cspec, _m} -> cspec.id end),
        sync_strategy
      )

      Distributor.children_redist_init(hub, added_node, children_data, [])

      HookManager.dispatch_hook(
        hub.storage.hook,
        Hook.children_migrated(),
        {added_node, children_data}
      )

      :ok
    end
  end
end
