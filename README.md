# ProcessHub

## Table of Contents

  - [Description](#module-description)
  - [Features](#module-features)
  - [Installation](#module-installation)
  - [Configurable strategies](#module-configuration)
  - [Distribution strategy](#module-default-distribution-strategy)
  - [Cluster discovery and formation](#module-cluster-discovery-and-formation)
  - [Resilience and reliability](#module-resilience-and-reliability)
  - [Locking mechanism](#module-locking-mechanism)
  - [Hooks](#module-hooks)
  - [Contributing](#module-contributing)
  - [Types](#types)
  - [Public API functions](#functions)

  ## Description

  Library for distributing processes safely across a cluster of nodes.
  It ships with a globally synchronized process registry that can be used for process lookups.

  ProcessHub is designed to be **decentralized** in its architecture. It does not rely on a
  single node to manage the cluster. Each node in the cluster is considered equal.
  Consensus is achieved by using a hash ring implementation.

  > ProcessHub is built with scalability and availability in mind.
  > Most of the operations are asynchronous and non-blocking.
  > It can guarantee **eventual** consistency.

  ProcessHub provides a set of configurable strategies for building distributed
  applications in Elixir.

  > #### ProcessHub requires a distributed node
  > ProcessHub is distributed in its nature, and for that reason, it needs to
  > **operate in a distributed environment**.
  > This means that the Elixir instance has to be started as a distributed node.
  > For example: `iex --sname mynode --cookie mycookie -S mix`.
  >
  > If the node is not started as a distributed node, starting the `ProcessHub` will fail
  > with the following error: `{:error, :local_node_not_alive}`

  ## Features

  Main features include:
  - Distributing processes across a cluster of nodes.
  - Distributed and synchronized process registry for fast lookups.
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
          {:process_hub, "~> 0.1.0-alpha"}
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

  ## Configurable strategies

  ProcessHub comes with 9 different strategies that can be used to configure the hub.
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
          redundancy_signal: :all
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
        }
      }}
    end
  end
  ```

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
  the state from the old process to the new process.

  ### Synchronization Strategy
  `ProcessHub.Strategy.Synchronization.Base` - defines the base protocol for synchronization
  strategies which define the method that is used to synchronize the process registry.

  Available strategies are:
  - `ProcessHub.Strategy.Synchronization.PubSub` - uses a publish/subscribe model to synchronize
  the process registry. Each node in the cluster will subscribe to a topic and publish any changes to the topic. These changes could be events such as adding or removing a process from the registry. This is the default strategy.
  - `ProcessHub.Strategy.Synchronization.Gossip` - uses a gossip protocol to synchronize the
  process registry. Using this strategy is only recommended when the underlying network is not
  reliable. The Gossip strategy selects a predefined number of nodes to gossip with and
  exchange information about the process registry.
  These selected nodes will choose other nodes to gossip with and so on until all nodes in the
  cluster are synchronized. This strategy has higher latency than the PubSub strategy and in some
  cases can lead to higher bandwidth usage or even decreased bandwidth usage depending on
  the number of nodes in the cluster.

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
    > #### Using DynamicQuorum Strategy
    > When scaling down too many nodes at once, the system may consider itself to be in a
    > network partition. Read the documentation for the
    >`ProcessHub.Strategy.PartitionTolerance.DynamicQuorum` strategy for more information.

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

  ## Hooks
  Hooks are used to trigger events on specific actions. Hooks can be registered by passing the
  handlers to the `:hooks` option of the `%ProcessHub{}` configuration struct or by inserting them
  dynamically using the `ProcessHub.Service.HookManager` module.

  ProcessHub heavily uses hooks internally in the integration tests.

  Hooks have to be in the format of an `mfa` tuple. Basically, they are functions that will be called
  when the hook is triggered.

  It is possible to register a hook handler with a wildcard argument `:_`, which will be replaced
  with the hook data when the hook is dispatched.

  Example:
  ```elixir
  # Register a hook handler for the `:cluster_join` event with a wildcard argument.
  ProcessHub.Service.HookManager.register_hook(:my_hub, ProcessHub.Constant.Hook.cluster_join(), {MyModule, :my_function, [:something, :_]})

  # The hook handler should be in the following format:
  def my_function(some_data, dynamic_hook_data), do: :ok
  ```

  ### Available hooks
  - `:cluster_join` - triggered when a new node is registered under the ProcessHub cluster.
  - `:cluster_leave` - triggered when a node is unregistered from the ProcessHub cluster.
  - `:registry_pid_inserted` - triggered when a new process is registered in the ProcessHub registry.
  - `:registry_pid_removed` - triggered when a process is unregistered from the ProcessHub registry.
  - `:child_migrated` - triggered when a process is migrated to another node.
  - `:priority_state_updated` - triggered when the priority level of the local event queue has been updated.
  - `:pre_nodes_redistribution` - triggered before processes are redistributed.
  - `:post_nodes_redistribution` - triggered after processes are redistributed.

    See `ProcessHub.Constant.Hook` module for more information.

  ## Contributing
  Contributions are welcome and appreciated. If you have any ideas, suggestions, or bugs to report,
  please open an issue or a pull request on GitHub.