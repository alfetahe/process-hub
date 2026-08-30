defmodule Test.Support.RemoteManifestContract do
  @moduledoc """
  Shared contract suite for `ProcessHub.Storage.RemoteManifest` adapters.

  `use` it with an `:adapter` module and an `opts_fun` context key (a 0-arity
  function built per test in `setup`, returning the adapter opts). Every adapter
  — built-in or external — must pass this suite unchanged.
  """

  defmacro __using__(adapter: adapter) do
    quote do
      @adapter unquote(adapter)

      defp hub_id_for_contract, do: :"manifest_hub_#{System.unique_integer([:positive])}"

      describe "#{inspect(@adapter)} contract" do
        test "fetch on an empty store is :not_found", %{opts_fun: opts_fun} do
          assert @adapter.fetch(hub_id_for_contract(), opts_fun.()) == :not_found
        end

        test "store then fetch round-trips the version and blob byte-identically",
             %{opts_fun: opts_fun} do
          opts = opts_fun.()
          hub_id = hub_id_for_contract()
          blob = :erlang.term_to_binary(%{payload: :something, n: 42})

          assert :ok = @adapter.store(hub_id, 7, blob, opts)
          assert {:ok, {7, ^blob}} = @adapter.fetch(hub_id, opts)
        end

        test "a higher version replaces, a lower or equal one is superseded",
             %{opts_fun: opts_fun} do
          opts = opts_fun.()
          hub_id = hub_id_for_contract()

          assert :ok = @adapter.store(hub_id, 50, "v50", opts)
          assert :ok = @adapter.store(hub_id, 51, "v51", opts)
          assert {:ok, {51, "v51"}} = @adapter.fetch(hub_id, opts)

          # A stale writer cannot clobber the newer copy.
          assert :ok = @adapter.store(hub_id, 48, "v48", opts)
          assert {:ok, {51, "v51"}} = @adapter.fetch(hub_id, opts)

          assert :ok = @adapter.store(hub_id, 51, "v51-again", opts)
          assert {:ok, {51, "v51"}} = @adapter.fetch(hub_id, opts)
        end

        test "hubs do not share manifests", %{opts_fun: opts_fun} do
          opts = opts_fun.()
          hub_a = hub_id_for_contract()
          hub_b = hub_id_for_contract()

          assert :ok = @adapter.store(hub_a, 1, "a", opts)
          assert @adapter.fetch(hub_b, opts) == :not_found
        end

        test "info returns a descriptive map", %{opts_fun: opts_fun} do
          assert %{adapter: _} = @adapter.info(opts_fun.())
        end
      end
    end
  end
end
