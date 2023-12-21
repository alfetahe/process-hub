# alias :hash_ring, as: HashRing
# alias :hash_ring_node, as: HashRingNode

Cachex.start_link(:test)
{:ok, val} = Cachex.get(:test, "hello")

another_val = val || 5000 |> IO.inspect()

# Cachex.put(:test, "hello", HashRing.make([HashRingNode.make(node())]))

# Benchee.run(
#   %{
#     "cache.get" => fn ->
#       Cachex.get(:test, "hello")
#     end,
#     "raw.create" => fn ->
#       HashRing.make([HashRingNode.make(node())])
#     end
#   },
#   warmup: 4,
#   time: 10,
#   parallel: 1
# )
