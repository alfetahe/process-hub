# ProcessHub

![example workflow](https://github.com/alfetahe/process-hub/actions/workflows/elixir.yml/badge.svg)  [![hex.pm version](https://img.shields.io/hexpm/v/coverex.svg?style=flat)](https://hex.pm/packages/process_hub) [![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/process_hub)

**NOTE: This library is still in alpha stage and is not recommended for production use.**

## Description

Library for building distributed systems that are scalable. It handles the distribution of
processes within a cluster of nodes while providing a globally synchronized process registry.

ProcessHub takes care of starting, stopping and monitoring processes in the cluster.
It scales automatically when cluster is updated and handles network partitions.

ProcessHub is designed to be **decentralized** in its architecture. It does not rely on a
single node to manage the cluster. Each node in the cluster is considered equal.
The default distribution strategy is based on consistent hashing.

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

## Installation

1. Add `process_hub` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [
        {:process_hub, "~> 0.3.3-alpha"}
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
  %{id: "process1", start: {MyProcess, :start_link, []}},
  %{id: "process2", start: {MyProcess, :start_link, []}}
])
{:ok, :start_initiated}
```

## Static process creation
Start the hub with 2 child specs. The hub will start the processes when it boots up.

```elixir
child_specs = [
  %{
    id: "my_process_1",
    start: {MyProcess, :start_link, []}
  },
  %{
    id: "my_process_2",
    start: {MyProcess, :start_link, []}
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
  my_process_1: [node_two@host: #PID<23772.233.0>],
  my_process_2: [node_one@user: #PID<0.250.0>],
]
```

Query processes by `child_id`:
```elixir
iex> ProcessHub.child_lookup(:my_hub, :my_process_1)
{
  %{id: :my_process_1, start: {MyProcess, :start_link, []}},
  [node_two@host: #PID<0.228.0>]
}
```

Find `pid` of a process by `child_id`:
```elixir
iex> ProcessHub.get_pid(:my_hub, :my_process_1)
#PID<0.228.0>
```

**See the [documentation](https://hexdocs.pm/process_hub) for more guides.**

## Contributing
Contributions are welcome and appreciated. If you have any ideas, suggestions, or bugs to report,
please open an issue or a pull request on GitHub.