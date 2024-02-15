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