defmodule ProcessHub.Migration.Handover do
  @moduledoc """
  Explicit state-handoff contract for hub-to-hub process migration.

  ProcessHub does **not** attempt transparent state capture. A process that wants
  to carry its state across a `ProcessHub.migrate_process/4` migration implements
  this behaviour:

    * `handover_export/1` runs on the source process's state (after it is frozen)
      and returns the term to transfer, and
    * `handover_import/2` runs on the freshly-started target process and merges the
      transferred term into its state, returning the new state.

  Both callbacks are **optional and pure** (no message round-trips). When a process
  implements neither, migration defaults to carrying the raw state across verbatim:
  the source state is transferred and replaces the target's initial state.

  ## Example

      defmodule Worker do
        use GenServer
        @behaviour ProcessHub.Migration.Handover

        @impl ProcessHub.Migration.Handover
        def handover_export(state), do: Map.take(state, [:counter, :cursor])

        @impl ProcessHub.Migration.Handover
        def handover_import(export, state), do: Map.merge(state, export)
      end
  """

  @doc "Called on the (frozen) source state; returns the term to transfer."
  @callback handover_export(state :: term()) :: export :: term()

  @doc "Called on the target process; merges `export` into `state`, returning the new state."
  @callback handover_import(export :: term(), state :: term()) :: new_state :: term()

  @optional_callbacks handover_export: 1, handover_import: 2
end
