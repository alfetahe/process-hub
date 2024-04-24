defmodule ProcessHub.MixProject do
  use Mix.Project

  def project do
    [
      app: :process_hub,
      version: "0.2.3-alpha",
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
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/Introduction.md",
          "guides/Architecture.md",
          "guides/Configuration.md",
          "guides/StateHandover.md",
          "guides/ManualDistribution.md",
          "guides/ReplicatingProcesses.md",
          "guides/Hooks.cheatmd"
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
      {:blockade, "~> 0.2.1"},
      {:hash_ring, "~> 0.4.2"},
      {:cachex, "~> 3.6"},
      {:ex_doc, "~> 0.30.6", only: :dev, runtime: false},
      {:benchee, "~> 1.2", only: :dev}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/helper"]
  defp elixirc_paths(_), do: ["lib"]
end
