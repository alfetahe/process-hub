defmodule ProcessHub.MixProject do
  use Mix.Project

  def project do
    [
      app: :process_hub,
      version: "0.6.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "ProcessHub",
      description: "Distributed processes manager and global process registry",
      source_url: "https://github.com/alfetahe/process-hub",
      package: [
        files: ~w(lib .formatter.exs mix.exs README* LICENSE*),
        licenses: ["GPL-3.0"],
        links: %{
          "GitHub" => "https://github.com/alfetahe/process-hub",
          "Changelog" => "https://github.com/alfetahe/process-hub/blob/master/CHANGELOG.md"
        }
      ],
      test_coverage: [
        ignore_modules: [
          Test.Helper.Common,
          Test.Helper.SetupHelper,
          Test.Helper.TestServer,
          Test.Helper.TestNode,
          Test.Helper.Bootstrap,
          Mix.Tasks.Benchmark,
          Test.Fixture.ScoreboardFixture,
          ProcessHub.Utility.Injector
        ]
      ],
      aliases: aliases(),
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/Introduction.md",
          "guides/ProcessRegistry.md",
          "guides/StartStop.md",
          "guides/Configuration.md",
          "guides/Persistence.md",
          "guides/StateHandover.md",
          "guides/Hooks.cheatmd",
          "guides/ManualDistribution.md",
          "guides/ReplicatingProcesses.md",
          "guides/CustomStrategy.md",
          "guides/Architecture.md"
        ],
        authors: ["Anuar Alfetahe"],
        filter_modules: fn module, _metadata ->
          mod_str = Atom.to_string(module)

          not String.starts_with?(mod_str, "Elixir.Test.") and
            not String.starts_with?(mod_str, "Elixir.Mix.Tasks.")
        end,
        nest_modules_by_prefix: [
          ProcessHub.Strategy.Distribution,
          ProcessHub.Strategy.Migration,
          ProcessHub.Strategy.Synchronization,
          ProcessHub.Strategy.Redundancy,
          ProcessHub.Strategy.PartitionTolerance,
          ProcessHub.Service,
          ProcessHub.Request.Handler,
          ProcessHub.Worker,
          ProcessHub.Task.ClusterUpdateTask,
          ProcessHub.Task.SynchronizationTask,
          ProcessHub.Constant,
          ProcessHub.Utility
        ],
        groups_for_modules: [
          "Public API": [ProcessHub],
          Core: [
            ProcessHub.Hub,
            ProcessHub.Initializer,
            ProcessHub.Coordinator,
            ProcessHub.DistributedSupervisor
          ],
          "Distribution Strategies": [
            ProcessHub.Strategy.Distribution.Base,
            ProcessHub.Strategy.Distribution.ConsistentHashing,
            ProcessHub.Strategy.Distribution.Guided,
            ProcessHub.Strategy.Distribution.CentralizedLoadBalancer
          ],
          "Migration Strategies": [
            ProcessHub.Strategy.Migration.Base,
            ProcessHub.Strategy.Migration.ColdSwap,
            ProcessHub.Strategy.Migration.HotSwap,
            ProcessHub.Strategy.Migration.SwapMigration,
            ProcessHub.Strategy.Migration.HandoverBehaviour
          ],
          "Synchronization Strategies": [
            ProcessHub.Strategy.Synchronization.Base,
            ProcessHub.Strategy.Synchronization.PubSub,
            ProcessHub.Strategy.Synchronization.Gossip
          ],
          "Redundancy Strategies": [
            ProcessHub.Strategy.Redundancy.Base,
            ProcessHub.Strategy.Redundancy.Singularity,
            ProcessHub.Strategy.Redundancy.Replication
          ],
          "Partition Tolerance Strategies": [
            ProcessHub.Strategy.PartitionTolerance.Base,
            ProcessHub.Strategy.PartitionTolerance.Divergence,
            ProcessHub.Strategy.PartitionTolerance.StaticQuorum,
            ProcessHub.Strategy.PartitionTolerance.DynamicQuorum,
            ProcessHub.Strategy.PartitionTolerance.MajorityQuorum
          ],
          Services: [
            ProcessHub.Service.Storage,
            ProcessHub.Service.Storage.Behaviour,
            ProcessHub.Service.Storage.Ets,
            ProcessHub.Service.Storage.Dets,
            ProcessHub.Service.ProcessRegistry,
            ProcessHub.Service.Distributor,
            ProcessHub.Service.RequestManager,
            ProcessHub.Service.Dispatcher,
            ProcessHub.Service.HookManager,
            ProcessHub.Service.Synchronizer,
            ProcessHub.Service.Cluster,
            ProcessHub.Service.State,
            ProcessHub.Service.Ring,
            ProcessHub.Service.LoggerService
          ],
          Requests: [
            ProcessHub.Request.CrossNodeRequest,
            ProcessHub.Request.PostAction,
            ProcessHub.Request.Handler.StartChildrenRequest,
            ProcessHub.Request.Handler.StartChildrenRequest.PostStartData,
            ProcessHub.Request.Handler.StopChildrenRequest,
            ProcessHub.Request.Handler.PidsRegisterRequest,
            ProcessHub.Request.Handler.PidsUnregisterRequest,
            ProcessHub.Request.Handler.PidUpdateRequest
          ],
          "Workers & Tasks": [
            ProcessHub.Worker.WorkerQueue,
            ProcessHub.Worker.BootstrapWorker,
            ProcessHub.Worker.Janitor,
            ProcessHub.Task.ClusterUpdateTask,
            ProcessHub.Task.ClusterUpdateTask.NodeUp,
            ProcessHub.Task.ClusterUpdateTask.NodeDown,
            ProcessHub.Task.SynchronizationTask,
            ProcessHub.Task.SynchronizationTask.IntervalSyncInit,
            ProcessHub.Task.SynchronizationTask.IntervalSyncHandle,
            ProcessHub.Task.SynchronizationTask.ProcessEmitHandle
          ],
          "Results & Futures": [
            ProcessHub.Future,
            ProcessHub.StartResult,
            ProcessHub.StopResult
          ],
          Constants: [
            ProcessHub.Constant.Event,
            ProcessHub.Constant.Hook,
            ProcessHub.Constant.StorageKey
          ],
          Utilities: [
            ProcessHub.Utility.Bag,
            ProcessHub.Utility.Extractor,
            ProcessHub.Utility.Injector
          ]
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:blockade, "~> 0.2.2"},
      {:hash_ring, "~> 0.4.2"},
      {:elector, "~> 0.3.3", runtime: false},
      {:ex_doc, "~> 0.34.2", only: :dev, runtime: false},
      {:benchee, "~> 1.5", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [docs: ["docs", &copy_images/1]]
  end

  defp copy_images(_) do
    File.cp_r("guides/assets", "doc/assets")
  end

  defp elixirc_paths(:prod), do: ["lib"]
  defp elixirc_paths(_), do: ["lib", "test/helper", "test/fixture", "test/support", "priv/mix/tasks"]
end
