defmodule Test.Helper.ConsentServer do
  @moduledoc """
  GenServer participating in the migration consent protocol with a
  configurable reply (`:consent_reply` in the init args, defaults to `:defer`).
  """

  use GenServer
  use ProcessHub.Strategy.Migration.MigrationConsent
  use ProcessHub.Strategy.Migration.HotSwap

  def start_link(args \\ %{}) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl GenServer
  def init(args), do: {:ok, args}

  @impl ProcessHub.Strategy.Migration.MigrationConsent
  def migration_consent(state), do: Map.get(state, :consent_reply, :defer)

  @impl GenServer
  def handle_call({:set_consent, reply}, _from, state) do
    {:reply, :ok, Map.put(state, :consent_reply, reply)}
  end
end

defmodule Test.Helper.DefaultConsentServer do
  @moduledoc """
  GenServer using the consent macro without overriding the callback, so it
  replies with the default `:ready`.
  """

  use GenServer
  use ProcessHub.Strategy.Migration.MigrationConsent

  def start_link(args \\ %{}) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl GenServer
  def init(args), do: {:ok, args}
end
