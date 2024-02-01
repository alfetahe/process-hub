# alias :hash_ring, as: HashRing
# alias :hash_ring_node, as: HashRingNode

Cachex.start_link(:test_cachex)

Cachex.put(:test_cachex, :key, :val)
:ets.new(:test_ets, [:set, :public, :named_table])
:ets.insert(:test_ets, {:key, :val})

Benchee.run(
  %{
    "cachex.get" => fn ->
      Cachex.get(:test_cachex, :coordinator)
    end,
    "ets.get" => fn ->
      :ets.lookup(:test_ets, :coordinator)
    end,
    "raw.create" => fn ->
      ProcessHub.Utility.Name.coordinator(:test)
    end
  },
  warmup: 2,
  time: 5,
  parallel: 4
)
