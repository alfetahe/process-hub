defmodule ProcessHub.Migration.Handover do
  @moduledoc """
  State-handover contract for `ProcessHub.migrate_process/4`, mirroring the
  `HotSwap`/`ColdSwap` migration strategies.

  > #### Opt in to state handover {: .info}
  >
  > A migrated process keeps its state only if it supports this contract. The
  > easiest way is to inject the macro, which provides overridable callbacks and
  > the required message handlers:
  >
  >     defmodule MyServer do
  >       use GenServer
  >       use ProcessHub.Migration.Handover
  >
  >       # Optionally override (defaults: identity / replace):
  >       # def prepare_handover_state(state), do: state
  >       # def alter_handover_state(_current, handover), do: handover
  >     end
  >
  > If you are not using a GenServer (or prefer manual control), implement the
  > two `handle_info/2` clauses yourself: reply to
  > `{:process_hub, :query_migration_handover_state, receiver, child_id}` with
  > `{:process_hub, :migration_state, child_id, state}`, and apply
  > `{:process_hub, :migration_handover, child_id, state}`. A process that
  > supports neither is migrated **without** its state.

  It reuses `ProcessHub.Strategy.Migration.HandoverBehaviour`
  (`prepare_handover_state/1`, `alter_handover_state/2`), so a process that
  already supports `HotSwap`/`ColdSwap` handover can share the same callbacks
  (pass `declare_behaviour: false` to avoid re-declaring them).
  """

  defmacro __using__(opts) do
    declare_behaviour = Keyword.get(opts, :declare_behaviour, true)

    behaviour_ast =
      if declare_behaviour do
        quote do
          @behaviour ProcessHub.Strategy.Migration.HandoverBehaviour

          @impl ProcessHub.Strategy.Migration.HandoverBehaviour
          def prepare_handover_state(state), do: state

          @impl ProcessHub.Strategy.Migration.HandoverBehaviour
          def alter_handover_state(_current_state, handover_state), do: handover_state

          defoverridable prepare_handover_state: 1, alter_handover_state: 2
        end
      end

    quote do
      unquote(behaviour_ast)

      @doc false
      def handle_info({:process_hub, :query_migration_handover_state, receiver, child_id}, state) do
        send(receiver, {:process_hub, :migration_state, child_id, prepare_handover_state(state)})
        {:noreply, state}
      end

      @doc false
      def handle_info({:process_hub, :migration_handover, _child_id, handover_state}, state) do
        {:noreply, alter_handover_state(state, handover_state)}
      end
    end
  end
end
