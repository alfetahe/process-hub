# ProcessHub

![example workflow](https://github.com/alfetahe/process-hub/actions/workflows/elixir.yml/badge.svg)  [![hex.pm version](https://img.shields.io/hexpm/v/coverex.svg?style=flat)](https://hex.pm/packages/process_hub)

## Description

Library for building distributed systems that are scalable. It handles the distribution of
processes within a cluster of nodes while providing a globally synchronized process registry.

ProcessHub takes care of starting, stopping and monitoring processes in the cluster.
It scales automatically when cluster is updated and handles network partitions.

Building distributed systems is hard and designing one is all about trade-offs.
There are many things to consider and each system has its own requirements. 
This library aims to be flexible and configurable to suit different use cases.

ProcessHub is designed to be **decentralized** in its architecture. It does not rely on a
single node to manage the cluster. Each node in the cluster is considered equal.
The default distribution strategy is based on consistent hashing.

Detailed documentation can be found at [https://hexdocs.pm/process_hub](https://hexdocs.pm/process_hub).

> ProcessHub is built with scalability and availability in mind.
> Most of the operations are asynchronous and non-blocking.
> It can guarantee **eventual** consistency.

ProcessHub provides a set of configurable strategies for building distributed
applications in Elixir.

> #### ProcessHub requires a distributed node {: .info}
> ProcessHub is distributed in its nature, and for that reason, it needs to
> **operate in a distributed environment**.
> This means that the Elixir instance has to be started as a distributed node.
> For example: `iex --sname mynode --cookie mycookie -S mix`.
>
> If the node is not started as a distributed node, starting the `ProcessHub` will fail
> with the following error: `{:error, :local_node_not_alive}`

## Features

Main features include:
- Distributing processes within a cluster of nodes.
- Distributed and synchronized process registry for fast process lookups.
- Process state handover.
- Strategies to handle network partitions, node failures, process migrations,
synchronization, distribution and more.
- Hooks for triggering events on specific actions and extend the functionality.
- Automatic hub cluster forming and healing when nodes join or leave the cluster.
- Ability to define custom strategies to alter the behavior of the system.

## Installation

1. Add `process_hub` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [
        {:process_hub, "~> 0.2.6-alpha"}
      ]
    end
    ```

2. Start the `ProcessHub` supervisor under your application supervision tree:

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
  It is possible to start multiple hubs under the same supervision tree.
  Each hub must have a unique `:hub_id`.

## Contributing
Contributions are welcome and appreciated. If you have any ideas, suggestions, or bugs to report,
please open an issue or a pull request on GitHub.