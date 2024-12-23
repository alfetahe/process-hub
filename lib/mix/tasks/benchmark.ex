defmodule Mix.Tasks.Benchmark do
  @moduledoc "Run benchmarks. Example: `mix benchmark 5 100`"
  @shortdoc "Runs benchmarks"

  @hub_id :benchmark_hub

  alias ProcessHub.Constant.Hook

  use Mix.Task

  @impl Mix.Task
  def run([nr_of_peers, nr_of_processes]) do
    nr_of_peers = String.to_integer(nr_of_peers)
    nr_of_processes = String.to_integer(nr_of_processes)

    bootstrap(nr_of_peers)

    Benchee.run(
      %{
        "start_processes" => fn ->
          start_processes(@hub_id, nr_of_processes)
        end
      },
      warmup: 4,
      time: 5,
      parallel: 1
    )
  end

  defp bootstrap(nr_of_peers) do
    Test.Helper.TestNode.start_local_node()

    listed_hooks = [
      {Hook.post_cluster_join(), :local}
    ]

    peer_nodes = Test.Helper.TestNode.start_nodes(nr_of_peers)

    settings = %{
      hub_id: :benchmark_hub,
      listed_hooks: listed_hooks,
      peer_nodes: peer_nodes
    }

    hub = Test.Helper.Bootstrap.gen_hub(settings)

    Test.Helper.Bootstrap.start_hubs(hub, [node() | Node.list()], listed_hooks)
  end

  defp start_processes(hub_id, nr_of_processes) do
    child_specs = ProcessHub.Utility.Bag.gen_child_specs(nr_of_processes)

    ProcessHub.start_children(hub_id, child_specs, async_wait: true) |> ProcessHub.await()
  end
end

# alias :hash_ring, as: HashRing
# alias :hash_ring_node, as: HashRingNode

# Cachex.start_link(:test_cachex)

# Cachex.put(:test_cachex, :key, :val)
# :ets.new(:test_ets, [:set, :public, :named_table])
# :ets.insert(:test_ets, {:key, :val})
