# Architecture

## Table of Contents
* [Overview](#overview)
* [Cluster Discovery and Formation](#cluster-discovery-and-formation)
* [Resilience and Reliability](#resilience-and-reliability)
* [Locking Mechanism](#locking-mechanism)

## Overview
The overall architecture of ProcessHub is designed to provide a reliable and resilient
distributed system that can handle network partitions, node failures, process migrations,

This is mostly achieved by asynchronous and non-blocking operations, and by using the
`Supervisor` behavior to monitor and restart processes when they die unexpectedly.

ProcessHub is eventually consistent meaning that it can guarantee that the state of the
system will eventually converge to a consistent state. This enables the system to be
scalable and highly available. 

ProcessHub internally uses a event-driven communication and ability to define listeners/hooks.
This enables some type of way to react to specific events such as process registration etc.

Most of the operations are carried out using special Task processes. These processes are
started on demand by the `ProcessHub.Coordinator` process and are supervised by the `Task.Supervisor`.

The coordinator process is responsible for coordinating the operations and making sure that
the operations are carried out in the correct order. This process is the heart of the system and
is responsible for the overall functionality of the system.

## Supervision tree
![supervision_tree](https://raw.githubusercontent.com/alfetahe/process-hub/master/guides/assets/images/supervision-tree.png)

## Processes

- `coordinator` - The coordinator process is responsible for coordinating the operations and making sure that the operations are carried out in the correct order. This process is the heart of the system and is responsible for the overall functionality of the system. 
All actions are dispatched to the coordinator process who then delegates the work to the correct handler process.

- `distributed_supervisor` - The distributed supervisor process is responsible for starting, stopping, and monitoring the processes in its local cluster. It uses the `Supervisor` behavior to monitor the processes and restart them when they die unexpectedly.

- `event_queue_sup` (external library) - The event queue supervisor starts and supervises the event queue  processes. The event queue is used to dispatch events within the Erlang distribution system to all nodes in the cluster. This provides a way to communicate between nodes and synchronize the operations in the system.
These processes are started by external library `blockade`.

- `janitor` - The janitor process is responsible for cleaning up the system and removing any stale data. It periodically checks the system for any stale data and removes it to keep the system clean and efficient.

- `task_supervisor` - The task supervisor process is responsible for supervising the task processes that are started on demand by the coordinator process. These processes are used to carry out the operations in the system and are supervised by the task supervisor process.

- `worker_queue` - The worker queue process is used to synchronize the operations that may introduce race conditions.

- `bootstrap_worker` - The bootstrap worker performs the hub's startup work, such as starting the statically configured `child_specs`.

- `process_registry` - The process registry process owns the registry storage and serializes writes to it.

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

## Work Serialization
ProcessHub utilizes the `:blockade` library to provide event-driven communication.

Operations that must not interleave are delegated to the worker queue
(`ProcessHub.Worker.WorkerQueue`), which runs them one at a time in the order they were
received. This preserves data integrity without blocking the coordinator itself.

`ProcessHub.is_locked?/1` reports whether the coordinator has delegated work that has
not completed yet. It is informational only and does not block event processing.