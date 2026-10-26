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
  Called on the old process right after `c:prepare_handover_state/1`.
  Returns the process's own new state, so the process can stop applying work
  once its state has been read, for example to hold it and forward it later.

  The default implementation returns the state unchanged.
  """
  @callback handover_state_taken(state :: term()) :: term()

  @optional_callbacks handover_state_taken: 1

  @doc false
  # The behaviour declaration and default callbacks that the `HotSwap` and
  # `ColdSwap` `use` macros share.
  def __default_callbacks__ do
    quote do
      @behaviour ProcessHub.Strategy.Migration.HandoverBehaviour

      @impl ProcessHub.Strategy.Migration.HandoverBehaviour
      def prepare_handover_state(state), do: state

      @impl ProcessHub.Strategy.Migration.HandoverBehaviour
      def alter_handover_state(_current_state, handover_state), do: handover_state

      @impl ProcessHub.Strategy.Migration.HandoverBehaviour
      def handover_state_taken(state), do: state

      defoverridable prepare_handover_state: 1,
                     alter_handover_state: 2,
                     handover_state_taken: 1
    end
  end
end
