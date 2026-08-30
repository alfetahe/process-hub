# ProcessHub

![example workflow](https://github.com/alfetahe/process-hub/actions/workflows/elixir.yml/badge.svg)  [![hex.pm version](https://img.shields.io/hexpm/v/coverex.svg?style=flat)](https://hex.pm/packages/process_hub) [![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/process_hub)

## Description

Library for building distributed systems that are scalable. It handles the distribution of
processes within a cluster of nodes while providing a globally synchronized process registry.

ProcessHub takes care of starting, stopping and monitoring processes in the cluster.
It scales automatically when cluster is updated and handles network partitions.

ProcessHub provides different configuration options to define whether it operates in a
**decentralized** or **leader-based** architecture. The default distribution strategy is
decentralized and based on consistent hashing, where each node in the cluster is considered
equal. Alternatively, you can configure ProcessHub to use a centralized load balancer
strategy that relies on a leader node to make distribution decisions based on real-time
cluster metrics.

> #### ProcessHub is eventually consistent {: .info}
> ProcessHub is built with scalability and availability in mind. 
> Most of the operations are asynchronous and non-blocking. It can guarantee **eventual consistency**.
>
> The system may not be in a consistent state at all times, 
> but it will eventually converge to a consistent state.

## Features

Main features include:
- Automatically or manually distribute processes within a cluster of nodes.
- Distributed and synchronized process registry for fast process lookups.
- Process monitoring and automatic restart on failures (`Supervisor`).
- Process state handover on process migration.
- Provides different strategies out of the box to handle: 
  - Process migrations.
  - Process distribution.
  - Process synchronization.
  - Process replication.
  - Cluster partitioning.
- Hooks for triggering events on specific actions and extend the functionality.
- Automatic hub cluster forming and healing when nodes join or leave the cluster.
- Customizable and extendable to alter the default behavior of the system by implementing custom hook handlers and strategies.
- Optional disk-backed (DETS) registry that survives coordinator restart on a single node — opt in via `:registry_backend`. See [Persistence](guides/Persistence.md).

## Installation

1. Add `process_hub` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [
        {:process_hub, "~> 0.7.0"}
      ]
    end
    ```

2. Run `mix deps.get` to fetch the dependencies.    

3. Add `ProcessHub` to your application's supervision tree:

    ```elixir
    defmodule MyApp.Application do
      use Application

      def start(_type, _args) do
        children = [
          ProcessHub.child_spec(%ProcessHub{hub_id: :my_hub})
        ]

        opts = [strategy: :one_for_one, name: MyApp.Supervisor]
        Supervisor.start_link(children, opts)
      end
    end
    ```
  It is possible to start multiple hubs under the same supervision tree, each
  with a unique `:hub_id`.
  By doing so, each hub will have its own cluster of processes. 
  All hubs will be independent of each other.

  For example we can start two separate hubs with different configurations.

## Dynamic process creation
Dynamically create 2 distributed processes under the hub `:my_hub`. These processes are
started asynchronously by default and are monitored by the hub.

```elixir
iex> ProcessHub.start_children(:my_hub, [
  %{id: "process1", start: {MyProcess, :start_link, [nil]}},
  %{id: "process2", start: {MyProcess, :start_link, [nil]}}
])
{:ok, :start_initiated}
```

## Static process creation
Start the hub with 2 child specs. The hub will start the processes when it boots up.

```elixir
child_specs = [
  %{
    id: "my_process_1",
    start: {MyProcess, :start_link, [nil]}
  },
  %{
    id: "my_process_2",
    start: {MyProcess, :start_link, [nil]}
  }
]

# Start under the supervision tree.
ProcessHub.child_spec(%ProcessHub{
  hub_id: :my_hub,
  child_specs: child_specs
})
```

## Process lookup

Query the whole registry for all processes under the hub `:my_hub`:
```elixir
iex> ProcessHub.process_list(:my_hub, :global)
[
  {"my_process_1", [node_two@host: #PID<23772.233.0>]},
  {"my_process_2", [node_one@user: #PID<0.250.0>]}
]
```

Query processes by `child_id`:
```elixir
iex> ProcessHub.child_lookup(:my_hub, "my_process_1")
{
  %{id: "my_process_1", start: {MyProcess, :start_link, [nil]}},
  [node_two@host: #PID<0.228.0>]
}
```

Find `pid` of a process by `child_id`:
```elixir
iex> ProcessHub.get_pid(:my_hub, "my_process_1")
#PID<0.228.0>
```

## Configuration

ProcessHub runs with sensible defaults — `%ProcessHub{hub_id: :my_hub}` is a
complete, valid configuration. Behaviour is customized through the
`%ProcessHub{}` struct (see `t:ProcessHub.t/0`), which lets you swap the
distribution, migration, synchronization, replication and partition-tolerance
strategies and optionally make the process registry disk-backed.

```elixir
ProcessHub.child_spec(%ProcessHub{
  hub_id: :my_hub,
  # Migrate process state to the target node during redistribution.
  migration_strategy: %ProcessHub.Strategy.Migration.HotSwap{},
  # Run each process on 2 nodes for redundancy.
  redundancy_strategy: %ProcessHub.Strategy.Redundancy.Replication{replication_factor: 2},
  # Stay available only while a quorum of nodes is connected.
  partition_tolerance_strategy: %ProcessHub.Strategy.PartitionTolerance.StaticQuorum{quorum_size: 2},
  # Persist the registry to disk so a single-node restart keeps its children.
  registry_backend: {:dets, path: "priv/my_hub.dets"}
})
```

See [guides/Configuration.md](guides/Configuration.md) for the configurable
strategies, `t:ProcessHub.t/0` for the full set of hub options, and
[guides/Persistence.md](guides/Persistence.md) for the optional disk-backed
registry and coordinator recovery.

## Getting started 📚

New to ProcessHub? **Start with the [Getting started guide](https://hexdocs.pm/process_hub/introduction.html)** — it walks you through installation, configuration, and your first distributed processes.

Browse the [full documentation](https://hexdocs.pm/process_hub) for all guides and the API reference.

## Contributing
Contributions are welcome and appreciated. If you have any ideas, suggestions, or bugs to report,
please open an issue or a pull request on GitHub.

## License
Copyright 2023 Anuar Alfetahe. Licensed under the [Apache License, Version 2.0](LICENSE).
