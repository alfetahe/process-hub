# Configuring the hub

## Configurable strategies

ProcessHub comes with 12 different strategies that can be used to configure the hub.
All strategies are Elixir structs that implement their own base protocol.

In fact, you can define your own strategies by implementing the base protocols.

When configuring the hub, you can pass the strategies as part of the `%ProcessHub{}` struct.

Look at the documentation for each strategy for more information on how to configure them.

An example can be seen below.
```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [process_hub()]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp process_hub() do
    {ProcessHub, %ProcessHub{
      hub_id: :my_hub,
      # Configure the redundancy strategy.
      redundancy_strategy: %ProcessHub.Strategy.Redundancy.Replication{
        replication_factor: 2,
        replication_model: :active_passive,
        redundancy_signal: :none
      },
      # Configure the migration strategy.
      migration_strategy: %ProcessHub.Strategy.Migration.HotSwap{
        retention: 2000,
        handover: true
      },
      # Configure the synchronization strategy.
      synchronization_strategy: %ProcessHub.Strategy.Synchronization.PubSub{
        sync_interval: 10000
      },
      # Configure the partition tolerance strategy.
      partition_tolerance_strategy: %ProcessHub.Strategy.PartitionTolerance.StaticQuorum{
        quorum_size: 3
      },
      # Configure the distribution strategy.
      distribution_strategy: %ProcessHub.Strategy.Distribution.ConsistentHashing{}
    }}
  end
end
```

Each strategy module has additional documentation on how to configure it.

### Redundancy Strategy
`ProcessHub.Strategy.Redundancy.Base` - defines the base protocol for redundancy strategies.
This strategy is used to define how many replicas of a process should be started
across the cluster. Starting multiple instances of a process across the cluster is useful
for redundancy and fault tolerance.

Available strategies are:
- `ProcessHub.Strategy.Redundancy.Singularity` - only 1 process per `child_id` without
any replicas. This is also the default strategy and contains no special configuration options.
- `ProcessHub.Strategy.Redundancy.Replication` - starts multiple replicas of a process
across the cluster. The number of replicas is defined by the `:replication_factor`
option. This strategy also supports `:active_active` and `:active_passive` modes.
Meaning we may have one active process and the rest are passive.
The mode is defined by the `:replication_model` option.
This information will be passed to the started process.
The default mode is `:active_active`, meaning all processes are equal and considered active.

### Migration Strategy
`ProcessHub.Strategy.Migration.Base` - defines the base protocol for migration strategies.
This strategy is used to define how the processes are migrated when a node joins or leaves the cluster.

Migration is the process of moving processes from one node to another.
One of the reasons why migration happens is when a node leaves the cluster.
When a node leaves the cluster, it is possible that some processes are still running on that
node, so these need to be migrated to another node. Also, when a new node joins the
cluster, other nodes may migrate some processes over to the new node.

At the moment, there are 2 migration strategies available:
- `ProcessHub.Strategy.Migration.ColdSwap` - migrate processes by stopping the process
on the old node before starting it on the new node. This is the default strategy and defines no special configuration options.
- `ProcessHub.Strategy.Migration.HotSwap` - this strategy is used to migrate processes
by starting the process on the new node before stopping it on the old node.
This strategy is useful when we want to avoid any downtime. This strategy is also
useful when the process is stateful, and we want to avoid any data loss by handing over
the state from the old process to the new process. See the module for handover examples.

### Synchronization Strategy
`ProcessHub.Strategy.Synchronization.Base` - defines the base protocol for synchronization
strategies which define the method that is used to synchronize the process registry.

Available strategies are:
- `ProcessHub.Strategy.Synchronization.PubSub` - uses a publish/subscribe model to synchronize
the process registry. Each node in the cluster will subscribe to a topic and publish any changes to the topic.
These changes could be events such as adding or removing a process from the registry.
This is the default and recommended synchronization strategy for most users.
- `ProcessHub.Strategy.Synchronization.Gossip` - uses a gossip protocol to synchronize the
process registry. Using this strategy is recommended when the number of nodes in the cluster
is large. The Gossip strategy selects a predefined number of nodes to gossip with and
exchange information about the process registry.
These selected nodes will choose other nodes to gossip with and so on until all nodes in the
cluster are synchronized. It has higher latency than the PubSub strategy specially when the cluster
is rather small.

### Partition Tolerance Strategy
`ProcessHub.Strategy.PartitionTolerance.Base` - defines the base protocol for partition tolerance
strategies which define the method that is used to handle network partitions.

Available strategies are:
- `ProcessHub.Strategy.PartitionTolerance.Divergence` - this strategy is used to handle network
partitions by diverging the cluster into multiple subclusters. Each subcluster will have its
own hub and will be considered as a separate cluster. This strategy is the default strategy.
When the network partition is healed, the subclusters will merge back into a single cluster.
- `ProcessHub.Strategy.PartitionTolerance.StaticQuorum` - this strategy is used to handle network
partitions by using a static quorum. The quorum size is defined by the `:quorum_size` option.
When a partition happens, the `ProcessHub.DistributedSupervisor` process will terminate
along with its children. This strategy is useful when the number of nodes in the cluster is
known and rather fixed.
- `ProcessHub.Strategy.PartitionTolerance.DynamicQuorum` - this strategy is used to handle
network partitions by using a dynamic quorum. The quorum size is defined by the `:quorum_size`
option and `:threshold_time` option. The system automatically over time adapts to the number of
nodes in the cluster. When a partition happens, the `ProcessHub.DistributedSupervisor` process
will terminate along with its children.
  > #### Using DynamicQuorum Strategy {: .error}
  > When scaling down too many nodes at once, the system may consider itself to be in a
  > network partition. Read the documentation for the
  >`ProcessHub.Strategy.PartitionTolerance.DynamicQuorum` strategy for more information.

### Distribution Strategy:
`ProcessHub.Strategy.Distribution.Base` - defines the base protocol for distribution
strategies which define the method to determine the node/process mapping.

ProcessHub currently supports 3 distribution strategies:

- `ProcessHub.Strategy.Distribution.ConsistentHashing` - uses a consistent hash ring to determine
the node/process mapping. This strategy is the default strategy and operates in a decentralized manner.
Each node is responsible for a range of hash values, and process IDs are hashed to determine their
node assignment. When the cluster topology changes, only affected processes are redistributed,
minimizing unnecessary migrations. Supports process replication and requires no configuration options.

- `ProcessHub.Strategy.Distribution.Guided` - uses a predefined mapping to determine the
node/process mapping. This strategy is useful when we want to control the mapping of
processes to nodes. You must explicitly specify which nodes each child process should run on
during startup. Processes are bound to their assigned nodes and **do not support migration**.
This is ideal for scenarios requiring specific node placement based on hardware requirements
or geographic distribution.

- `ProcessHub.Strategy.Distribution.CentralizedLoadBalancer` - uses a leader-based approach where
a single leader node collects performance metrics from all nodes and makes distribution decisions
based on real-time load data. The leader is determined by highest uptime and is not configurable.

  > #### Experimental Strategy {: .warning}
  > The `CentralizedLoadBalancer` strategy is currently **experimental** and should not be used
  > in production environments.

  **Configuration options:**
  - `:max_history_size` (default: 30) - Maximum historical load scores to maintain
  - `:weight_decay_factor` (default: 0.9) - Exponential decay factor for historical scores
  - `:push_interval` (default: 10,000) - Metrics collection interval in milliseconds
  - `:nodeup_redistribution` (default: false) - Process redistribution on node join (should not be changed)