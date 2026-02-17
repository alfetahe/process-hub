defmodule Test.Strategy.Distribution.GuidedTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.Distribution.Guided
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey

  setup do
    hub_id = :"test_guided_#{:erlang.unique_integer([:positive])}"
    misc_storage = :ets.new(hub_id, [:set, :public, :named_table])
    hook_storage = :ets.new(:"hook_#{hub_id}", [:set, :public])

    hub = %ProcessHub.Hub{
      hub_id: hub_id,
      storage: %{misc: misc_storage, hook: hook_storage}
    }

    on_exit(fn ->
      if :ets.whereis(hub_id) != :undefined, do: :ets.delete(hub_id)

      try do
        :ets.delete(hook_storage)
      rescue
        _ -> :ok
      end
    end)

    %{hub: hub, misc_storage: misc_storage}
  end

  describe "deterministic?/1" do
    test "returns true" do
      assert DistributionStrategy.deterministic?(%Guided{})
    end
  end

  describe "distribution_signature/2" do
    test "returns consistent hash for same nodes", %{hub: hub} do
      nodes = [node(), :n2@host]
      Storage.insert(hub.storage.misc, StorageKey.hn(), nodes)

      sig1 = DistributionStrategy.distribution_signature(%Guided{}, hub)
      sig2 = DistributionStrategy.distribution_signature(%Guided{}, hub)

      assert sig1 == sig2
    end

    test "is order-independent", %{hub: hub} do
      Storage.insert(hub.storage.misc, StorageKey.hn(), [:a@host, :b@host])
      sig1 = DistributionStrategy.distribution_signature(%Guided{}, hub)

      Storage.insert(hub.storage.misc, StorageKey.hn(), [:b@host, :a@host])
      sig2 = DistributionStrategy.distribution_signature(%Guided{}, hub)

      assert sig1 == sig2
    end
  end

  describe "belongs_to/4" do
    test "returns stored mappings", %{hub: hub} do
      mappings = %{child1: [node()], child2: [:n2@host]}
      Storage.insert(hub.storage.misc, StorageKey.gdc(), mappings)

      strategy = %Guided{}
      result = DistributionStrategy.belongs_to(strategy, hub, [:child1, :child2], 1)

      assert result[:child1] == [node()]
      assert result[:child2] == [:n2@host]
    end

    test "returns empty list for unknown child_ids", %{hub: hub} do
      mappings = %{child1: [node()]}
      Storage.insert(hub.storage.misc, StorageKey.gdc(), mappings)

      strategy = %Guided{}
      result = DistributionStrategy.belongs_to(strategy, hub, [:unknown_child], 1)

      assert result[:unknown_child] == []
    end

    test "respects replication_factor by taking only N nodes", %{hub: hub} do
      mappings = %{child1: [:n1@host, :n2@host, :n3@host]}
      Storage.insert(hub.storage.misc, StorageKey.gdc(), mappings)

      strategy = %Guided{}
      result = DistributionStrategy.belongs_to(strategy, hub, [:child1], 2)

      assert length(result[:child1]) == 2
      assert result[:child1] == [:n1@host, :n2@host]
    end
  end

  describe "insert_child_mappings/2" do
    test "inserts new mappings when none exist", %{hub: hub} do
      mappings = %{child1: [node()], child2: [:n2@host]}
      assert :ok = Guided.insert_child_mappings(hub, mappings)

      stored = Storage.get(hub.storage.misc, StorageKey.gdc())
      assert stored == mappings
    end

    test "merges with existing mappings", %{hub: hub} do
      existing = %{child1: [node()]}
      Storage.insert(hub.storage.misc, StorageKey.gdc(), existing)

      new_mappings = %{child2: [:n2@host]}
      assert :ok = Guided.insert_child_mappings(hub, new_mappings)

      stored = Storage.get(hub.storage.misc, StorageKey.gdc())
      assert stored[:child1] == [node()]
      assert stored[:child2] == [:n2@host]
    end

    test "overwrites existing keys on merge", %{hub: hub} do
      existing = %{child1: [node()]}
      Storage.insert(hub.storage.misc, StorageKey.gdc(), existing)

      new_mappings = %{child1: [:n2@host]}
      assert :ok = Guided.insert_child_mappings(hub, new_mappings)

      stored = Storage.get(hub.storage.misc, StorageKey.gdc())
      assert stored[:child1] == [:n2@host]
    end
  end

  describe "init/2" do
    test "registers pre_children_start hook handler", %{hub: hub} do
      strategy = %Guided{}
      result = DistributionStrategy.init(strategy, hub)
      assert result == strategy

      handlers =
        ProcessHub.Service.HookManager.registered_handlers(
          hub.storage.hook,
          ProcessHub.Constant.Hook.pre_children_start()
        )

      assert length(handlers) == 1
      assert hd(handlers).id == :dg_pre_start_handler
    end
  end

  describe "handle_children_start/2" do
    test "inserts child mappings from request options", %{hub: hub} do
      request = %{options: [child_mapping: %{child1: [node()]}]}
      Guided.handle_children_start(hub, %{request: request})

      stored = Storage.get(hub.storage.misc, StorageKey.gdc())
      assert stored[:child1] == [node()]
    end

    test "handles empty child_mapping", %{hub: hub} do
      request = %{options: []}
      Guided.handle_children_start(hub, %{request: request})

      stored = Storage.get(hub.storage.misc, StorageKey.gdc())
      assert stored == %{} or stored == nil
    end
  end

  describe "children_init/4" do
    test "returns error when child_mapping is missing", %{hub: hub} do
      strategy = %Guided{}
      child_specs = [%{id: :child1}]

      result = DistributionStrategy.children_init(strategy, hub, child_specs, [])
      assert result == {:error, :missing_child_mapping}
    end

    test "returns error when child_mapping is not a map", %{hub: hub} do
      strategy = %Guided{}
      child_specs = [%{id: :child1}]

      result =
        DistributionStrategy.children_init(strategy, hub, child_specs, child_mapping: "not a map")

      assert result == {:error, :invalid_child_mapping}
    end

    test "returns error when child specs don't match mappings", %{hub: hub} do
      strategy = %Guided{}
      child_specs = [%{id: :child1}, %{id: :child2}]

      # Only map child1, not child2
      result =
        DistributionStrategy.children_init(strategy, hub, child_specs,
          child_mapping: %{child1: [node()]}
        )

      assert result == {:error, :child_mapping_mismatch}
    end

    test "returns error when replication factor doesn't match node count", %{hub: hub} do
      # Store a singularity strategy (replication_factor=1)
      Storage.insert(
        hub.storage.misc,
        StorageKey.strred(),
        %ProcessHub.Strategy.Redundancy.Singularity{}
      )

      strategy = %Guided{}
      child_specs = [%{id: :child1}]

      # Mapping has 2 nodes but replication factor is 1
      result =
        DistributionStrategy.children_init(strategy, hub, child_specs,
          child_mapping: %{child1: [node(), :n2@host]}
        )

      assert result == {:error, :child_replication_mismatch}
    end

    test "succeeds with valid mappings", %{hub: hub} do
      # Store a singularity strategy (replication_factor=1)
      Storage.insert(
        hub.storage.misc,
        StorageKey.strred(),
        %ProcessHub.Strategy.Redundancy.Singularity{}
      )

      strategy = %Guided{}
      child_specs = [%{id: :child1}]

      result =
        DistributionStrategy.children_init(strategy, hub, child_specs,
          child_mapping: %{child1: [node()]}
        )

      assert result == :ok

      # Verify mappings are stored
      stored = Storage.get(hub.storage.misc, StorageKey.gdc())
      assert stored[:child1] == [node()]
    end
  end
end
