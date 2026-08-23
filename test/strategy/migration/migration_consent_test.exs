defmodule Test.Strategy.Migration.MigrationConsentTest do
  use ExUnit.Case, async: true

  alias ProcessHub.Strategy.Migration.MigrationConsent
  alias Test.Helper.ConsentServer
  alias Test.Helper.DefaultConsentServer
  alias Test.Helper.TestServer

  describe "__using__/1" do
    test "exports the consent marker function" do
      assert DefaultConsentServer.__ph_migration_consent__()
      assert ConsentServer.__ph_migration_consent__()
      refute function_exported?(TestServer, :__ph_migration_consent__, 0)
    end

    test "injects a consent query handler replying :ready by default" do
      {:ok, pid} = DefaultConsentServer.start_link(%{})

      send(pid, {:process_hub, :migration_consent, self(), :child1})

      assert_receive {:process_hub, :migration_consent_reply, :child1, :ready}
    end

    test "overridden consent callback can defer" do
      {:ok, pid} = ConsentServer.start_link(%{consent_reply: :defer})

      send(pid, {:process_hub, :migration_consent, self(), :child2})

      assert_receive {:process_hub, :migration_consent_reply, :child2, :defer}
    end

    test "overridden consent callback can turn ready at runtime" do
      {:ok, pid} = ConsentServer.start_link(%{consent_reply: :defer})
      :ok = GenServer.call(pid, {:set_consent, :ready})

      send(pid, {:process_hub, :migration_consent, self(), :child3})

      assert_receive {:process_hub, :migration_consent_reply, :child3, :ready}
    end
  end

  describe "participates?/1" do
    # Detection relies on the module being loaded, which always holds for
    # locally running children; mirror that invariant here.
    setup do
      Code.ensure_loaded!(DefaultConsentServer)
      Code.ensure_loaded!(ConsentServer)
      :ok
    end

    test "accepts child specs whose start module exports the marker" do
      assert MigrationConsent.participates?(%{
               id: :c1,
               start: {DefaultConsentServer, :start_link, [%{}]}
             })

      assert MigrationConsent.participates?(%{
               id: :c2,
               start: {ConsentServer, :start_link, [%{}]}
             })
    end

    test "rejects plain modules and malformed child specs" do
      refute MigrationConsent.participates?(%{id: :c1, start: {TestServer, :start_link, [%{}]}})
      refute MigrationConsent.participates?(%{id: :c2})
      refute MigrationConsent.participates?(%{id: :c3, start: :invalid})
    end
  end
end
