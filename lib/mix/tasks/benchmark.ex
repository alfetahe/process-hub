defmodule Mix.Tasks.Benchmark do
  @moduledoc "Run benchmarks. Example: `mix benchmark 5 100`"
  @shortdoc "Runs benchmarks"

  @hub_id :benchmark_hub

  alias ProcessHub.Constant.Hook

  use Mix.Task

  @impl Mix.Task
  def run([nr_of_peers, nr_of_processes]) do
    IO.puts("--------- BENCHMARK START ---------")

    nr_of_peers = String.to_integer(nr_of_peers)
    nr_of_processes = String.to_integer(nr_of_processes)

    bootstrap(nr_of_peers)
    benchmark(@hub_id, nr_of_processes)

    # {total_start, _} =
    #   :timer.tc(
    #     fn ->
    #       :os.system_time(:millisecond)
    #       start_processes(@hub_id, nr_of_processes)
    #     end,
    #     :millisecond
    #   )

    # dbg(total_start)

    IO.puts("--------- BENCHMARK END ---------")
  end

  defp benchmark(hub_id, nr_of_processes) do
    # start_processes(hub_id, nr_of_processes) |> IO.inspect()

    Benchee.run(
      %{
        "start_processes" => fn ->
          start_processes(hub_id, nr_of_processes)
        end
      },
      memory_time: 5,
      warmup: 5,
      time: 10,
      parallel: 1
    )

    :ok
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

    ProcessHub.start_children(hub_id, child_specs, async_wait: true, timeout: 10_000)
    |> ProcessHub.await()
  end
end
