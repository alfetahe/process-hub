defmodule ProcessHub.Strategy.Migration.HandoverBehaviour do
  @moduledoc """
  Shared behaviour for migration state handover callbacks.

  This behaviour defines the callbacks used by both `HotSwap` and `ColdSwap`
  migration strategies for state handover during process migration.

  Implement these callbacks to customize how state is prepared before
  migration and how it's applied to the new process.
  """

  @doc """
  Called on the dying process to prepare state before migration.
  Return the state data to be transferred to the new process.

  The default implementation returns the state unchanged.
  """
  @callback prepare_handover_state(state :: term()) :: term()

  @doc """
  Called on the new process to apply the handover state.
  Return the new state for the process.

  The default implementation replaces the current state with the handover state.
  """
  @callback alter_handover_state(current_state :: term(), handover_state :: term()) :: term()
end
