defmodule ProcessHub.MixProject do
  use Mix.Project

  def project do
    [
      app: :process_hub,
      version: "0.4.1-beta",
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
      aliases: aliases(),
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/Introduction.md",
          "guides/ProcessRegistry.md",
          "guides/StartStop.md",
          "guides/Configuration.md",
          "guides/StateHandover.md",
          "guides/Hooks.cheatmd",
          "guides/ManualDistribution.md",
          "guides/ReplicatingProcesses.md",
          "guides/CustomStrategy.md",
          "guides/Architecture.md"
        ],
        authors: ["Anuar Alfetahe"]
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
      {:elector, "~> 0.3.2", runtime: false},
      {:ex_doc, "~> 0.34.2", only: :dev, runtime: false},
      {:benchee, "~> 1.2", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [docs: ["docs", &copy_images/1]]
  end

  defp copy_images(_) do
    File.cp_r("guides/assets", "doc/assets")
  end

  defp elixirc_paths(:prod), do: ["lib"]
  defp elixirc_paths(_), do: ["lib", "test/helper", "test/fixture", "priv/mix/tasks"]
end
