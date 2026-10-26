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

  @doc """
  Called on the process whose state is queried, in place of
  `c:prepare_handover_state/1`. Returns the state to hand over and the
  process's own new state, so the process can change how it behaves from the
  moment its state leaves, for example to stop accepting work.

  `HotSwap` only. The default returns `{prepare_handover_state(state), state}`.
  """
  @callback take_handover_state(state :: term()) :: {handover_state :: term(), state :: term()}

  @doc """
  Called on the old process when its replacement is running and has been sent
  the handed over state, just before the old process is terminated. Sent only
  to a process whose state was handed over. Return the new state.

  `HotSwap` only. The default returns the state unchanged.
  """
  @callback replaced_by(state :: term(), replacement :: pid()) :: term()

  @optional_callbacks take_handover_state: 1, replaced_by: 2
end
