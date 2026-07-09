defmodule ProcessHub.Strategy.Migration.MigrationConsent do
  @moduledoc """
  Opt-in migration consent, enabled by setting `consent_settings` on the
  `HotSwap` or `ColdSwap` migration strategy.

  Before migrating a participating child, the hub asks the process whether it
  may be moved. `:ready` migrates it through the regular migration path;
  `:defer` (or no reply within `:consent_timeout`) parks it in the deferred
  list, retried every `:retry_interval` and force-migrated after
  `:max_defer_time`. `ProcessHub.Service.Migration.migration_ready/2` signals
  readiness early.

  Participating processes `use` this module:

      defmodule MyServer do
        use GenServer
        use ProcessHub.Strategy.Migration.MigrationConsent

        # Optional override, defaults to :ready.
        def migration_consent(state), do: if(state.busy?, do: :defer, else: :ready)
      end

  Consent covers the primary instance only; Replication-managed replicas are
  unaffected. Detection reads the child spec `start` module, so processes
  started through wrapper modules migrate immediately. Forced migration uses
  the best-effort handover path, so `prepare_handover_state` should return
  resumable progress.
  """

  @typedoc """
  - `:consent_timeout` - shared deadline for consent replies (default: 5000)
  - `:retry_interval` - deferred-migration retry interval (default: 10000)
  - `:max_defer_time` - max deferral before forced migration (default: 600000)
  """
  @type t() :: %__MODULE__{
          consent_timeout: pos_integer(),
          retry_interval: pos_integer(),
          max_defer_time: pos_integer()
        }

  defstruct consent_timeout: 5_000, retry_interval: 10_000, max_defer_time: 600_000

  @doc "Returns whether the process consents to being migrated right now."
  @callback migration_consent(state :: term()) :: :ready | :defer

  defmacro __using__(_opts) do
    quote do
      @behaviour ProcessHub.Strategy.Migration.MigrationConsent

      @doc false
      def __ph_migration_consent__(), do: true

      @impl ProcessHub.Strategy.Migration.MigrationConsent
      def migration_consent(_state), do: :ready

      defoverridable migration_consent: 1

      @doc false
      def handle_info({:process_hub, :migration_consent, reply_to, child_id}, state) do
        send(
          reply_to,
          {:process_hub, :migration_consent_reply, child_id, migration_consent(state)}
        )

        {:noreply, state}
      end
    end
  end

  @doc "Returns whether the child spec's `start` module participates in consent."
  @spec participates?(ProcessHub.child_spec()) :: boolean()
  def participates?(%{start: {module, _fun, _args}}) when is_atom(module) do
    function_exported?(module, :__ph_migration_consent__, 0)
  end

  def participates?(_child_spec), do: false
end
