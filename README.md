# ProcessHub

![example workflow](https://github.com/alfetahe/process-hub/actions/workflows/elixir.yml/badge.svg)  [![hex.pm version](https://img.shields.io/hexpm/v/coverex.svg?style=flat)](https://hex.pm/packages/process_hub)


## Table of Contents
* [Description](#description)
* [Features](#features)
* [Installation](#installation)
* [Distribution Strategy](#distribution-strategy)   # TODO: add documentation about distribution strategy.
* [Cluster Discovery and Formation](#cluster-discovery-and-formation)
* [Resilience and Reliability](#resilience-and-reliability)
* [Locking Mechanism](#locking-mechanism)
* [Contributing](#contributing)

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

Documentation can be found at [https://hexdocs.pm/process_hub](https://hexdocs.pm/process_hub).

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
- Strategies for redundancy handling and process replication.
- Strategies for handling network failures and partitions automatically.
- Strategies for handling process migration and synchronization when nodes join/leave
the cluster automatically.
- Hooks for triggering events on specific actions.
- Automatic hub cluster forming and healing when nodes join or leave the cluster.

## Installation

1. Add `process_hub` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [
        {:process_hub, "~> 0.2.0-alpha"}
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

## Distribution Strategy
ProcessHub uses consistent hashing to distribute processes. When the cluster is updated, the
hash ring is recalculated. The recalculation is done in a way that each node is assigned a unique hash value, and they form a **hash ring**. Each node in the cluster keeps track of the ProcessHub cluster and updates its local hash ring accordingly.

To find the node that the process belongs to, the system will use the hash ring to calculate
the hash value of the process ID (`child_id`) and assign it to the node with the closest hash value.

When the cluster is updated and the hash ring is recalculated, it does not mean that all
processes will be shuffled. Only the processes that are affected by the change will be redistributed. This is done to avoid unnecessary process migrations.

For example, when a node leaves the cluster, only the processes that were running on that node
will be redistributed. The rest of the processes will stay on the same node. When a new node
joins the cluster, only some of the processes will be redistributed to the new node, and the rest will stay on the same node.

> The hash ring implementation **does not guarantee** that all processes will always be
> evenly distributed, but it does its best to distribute them as evenly as possible.

This strategy is used by default and is not configurable at the moment.

## Cluster Discovery and Formation
ProcessHub monitors connecting and disconnecting nodes and forms a cluster automatically
from the connected nodes that share the same `hub_id`. It's not required to start
the `ProcessHub` on all nodes in the cluster.

## Resilience and Reliability
ProcessHub uses the `Supervisor` behavior and leverages the features that come with it.
Each hub starts its own `ProcessHub.DistributedSupervisor` process, which is responsible for
starting, stopping, and monitoring the processes in its local cluster.

When a process dies unexpectedly, the `ProcessHub.DistributedSupervisor` will restart it
automatically.

ProcessHub also takes care of validating the `child_spec` before starting it and makes sure
it's started on the right node that the process belongs to.
If the process is being started on the wrong node, the initialization request will be forwarded
to the correct node.

## Locking Mechanism
ProcessHub utilizes the `:blockade` library to provide event-driven communication
and a locking mechanism.
It locks the local event queue by increasing its priority for some operations.
This allows the system to queue events and process them in order to preserve data integrity.
Other events can be processed once the priority level is set back to default.

To avoid deadlocks, the system places a timeout on the event queue priority and
restores it to its original value if the timeout is reached.

## Contributing
Contributions are welcome and appreciated. If you have any ideas, suggestions, or bugs to report,
please open an issue or a pull request on GitHub.