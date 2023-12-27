defmodule ProcessHub do
  # TODO: add documentation about distribution strategy.
  @moduledoc """
  This is the main public API module for the `ProcessHub` library.

  ## Table of Contents

  - [Description](#module-description)
  - [Features](#module-features)
  - [Installation](#module-installation)
  - [Example usage](#module-example-usage)
  - [Configurable strategies](#module-configurable-strategies)
  - [Distribution strategy](#module-distribution-strategy)
  - [Cluster discovery and formation](#module-cluster-discovery-and-formation)
  - [Resilience and reliability](#module-resilience-and-reliability)
  - [Locking mechanism](#module-locking-mechanism)
  - [Hooks](#module-hooks)
  - [Contributing](#module-contributing)
  - [Types](#types)
  - [Public API functions](#functions)


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
  Consensus is achieved by using a hash ring implementation.

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
  - Distribute processes within a cluster of nodes.
  - Provides globally synchronized process registry.
  - Automatic hub cluster forming and healing when nodes join or leave the cluster.
  - Process state handover.
  - Strategies for redundancy handling and process replication.
  - Strategies for handling network failures and partitions automatically.
  - Strategies for handling process migration and synchronization when nodes join/leave
  the cluster automatically.
  - Hooks for triggering events on specific actions.


  ## Installation

  1. Add `process_hub` to your list of dependencies in `mix.exs`:

      ```elixir
      def deps do
        [
          {:process_hub, "~> 0.1.4-alpha"}
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
    Each hub must have a unique `t:hub_id/0`.


  ## Example usage

  The following example shows how to start 2 elixir nodes, connect them and start processes
  under the `ProcessHub` cluster. This demonstrates how the processes are distributed within
  the cluster.

  **Note:** The examples below assume that the `ProcessHub` is already started under the
  supervision tree. If not please refer to the [Installation](#module-installation) section.

  **Note:** Make sure you have a GenServer module called `MyProcess` defined in your project.
  ```elixir
  defmodule MyProcess do
    use GenServer

    def start_link() do
      GenServer.start_link(__MODULE__, nil)
    end

    def init(_) do
      {:ok, nil}
    end
  end
  ```

  <!-- tabs-open -->

  ### Node 1

  Start the first node with the following command:

  ```bash
  iex --name node1@127.0.0.1 --cookie mycookie -S mix
  ```

  ```elixir
  # Run the following in the iex console to start 5 processes under the hub.
  iex> ProcessHub.start_children(:my_hub, [
  ...>  %{id: :some_id1, start: {MyProcess, :start_link, []}},
  ...>  %{id: :another_id2, start: {MyProcess, :start_link, []}},
  ...>  %{id: :child_3, start: {MyProcess, :start_link, []}},
  ...>  %{id: :child_4, start: {MyProcess, :start_link, []}},
  ...>  %{id: "the_last_child", start: {MyProcess, :start_link, []}}
  ...> ])
  {:ok, :start_initiated}

  # Check the started processes by running the command below.
  iex> ProcessHub.which_children(:my_hub, [:global])
  [
    node1@127.0.0.1: [
      {"the_last_child", #PID<0.250.0>, :worker, [MyProcess]},
      {:child_4, #PID<0.249.0>, :worker, [MyProcess]},
      {:child_3, #PID<0.248.0>, :worker, [MyProcess]},
      {:another_id2, #PID<0.247.0>, :worker, [MyProcess]},
      {:some_id1, #PID<0.246.0>, :worker, [MyProcess]}
    ]
  ]
  ```

  ### Node 2
  We will use this node to connect to the first node and see how the processes are
  automatically distributed.

  Start the second node.
  ```bash
  iex --name node2@127.0.0.1 --cookie mycookie -S mix
  ```

  ```elixir
  # Connect the second node to the first node.
  iex> Node.connect(:"node1@127.0.0.1")
  true

  # Check the started procsses by running the command below and
  # see how some of the processes are distributed to the second node.
  iex> ProcessHub.which_children(:my_hub, [:global])
  [
    "node2@127.0.0.1": [
      {:child_3, #PID<0.261.0>, :worker, [MyProcess]},
      {:some_id1, #PID<0.246.0>, :worker, [MyProcess]}
    ],
    "node1@127.0.0.1": [
      {"the_last_child", #PID<21674.251.0>, :worker, [MyProcess]},
      {:child_4, #PID<21674.250.0>, :worker, [MyProcess]},
      {:another_id2, #PID<21674.248.0>, :worker, [MyProcess]}
    ]
  ]
  ```
  <!-- tabs-close -->


  ## Configurable strategies

  ProcessHub comes with 9 different strategies that can be used to configure the hub.
  All strategies are Elixir structs that implement their own base protocol.

  In fact, you can define your own strategies by implementing the base protocols.

  When configuring the hub, you can pass the strategies as part of the `t:t/0` struct.

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
          quorum_size: 2
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
  - `ProcessHub.Strategy.Redundancy.Singularity` - only 1 process per `t:child_id/0` without
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

  ## Distribution Strategy
  ProcessHub uses consistent hashing to distribute processes. When the cluster is updated, the
  hash ring is recalculated. The recalculation is done in a way that each node is assigned a unique
  hash value, and they form a **hash ring**. Each node in the cluster keeps track of the ProcessHub
  cluster and updates its local hash ring accordingly.

  To find the node that the process belongs to, the system will use the hash ring to calculate
  the hash value of the process ID (`t:child_id/0`) and assign it to the node with the closest hash value.

  When the cluster is updated and the hash ring is recalculated, it does not mean that all
  processes will be shuffled. Only the processes that are affected by the change will be
  redistributed. This is done to avoid unnecessary process migrations.

  For example, when a node leaves the cluster, only the processes that were running on that node
  will be redistributed. The rest of the processes will stay on the same node. When a new node
  joins the cluster, only some of the processes will be redistributed to the new node, and the
  rest will stay on the same node.

  > The hash ring implementation **does not guarantee** that all processes will always be
  > evenly distributed, but it does its best to distribute them as evenly as possible.

  This strategy is used by default and is not configurable at the moment.

  ## Cluster Discovery and Formation
  ProcessHub monitors connecting and disconnecting nodes and forms a cluster automatically
  from the connected nodes that share the same `t:hub_id/0`. It's not required to start
  the `ProcessHub` on all nodes in the cluster.


  ## Resilience and Reliability
  ProcessHub uses the `Supervisor` behavior and leverages the features that come with it.
  Each hub starts its own `ProcessHub.DistributedSupervisor` process, which is responsible for
  starting, stopping, and monitoring the processes in its local cluster.

  When a process dies unexpectedly, the `ProcessHub.DistributedSupervisor` will restart it
  automatically.

  ProcessHub also takes care of validating the `t:child_spec/0` before starting it and makes sure
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
  handlers to the `:hooks` option of the `t:t/0` configuration struct or by inserting them
  dynamically using the `ProcessHub.Service.HookManager` module.

  ProcessHub heavily uses hooks internally in the integration tests.

  Hooks have to be in the format of an `mfa` tuple. Basically, they are functions that will be called
  when the hook is triggered.

  It is possible to register a hook handler with a wildcard argument `:_`, which will be replaced
  with the hook data when the hook is dispatched.

  Example hook registration using the `t:t/0` configuration struct:
  ```elixir
  # Register a hook handler for the `:cluster_join` event with a wildcard argument.
  defmodule MyApp.Application do
    use Application

    def start(_type, _args) do
      children = [
        ProcessHub.child_spec(%ProcessHub{
          hub_id: :my_hub,
          hooks: [
             ProcessHub.Constant.Hook.cluster_join(), {MyModule, :my_function, [:some_data, :_]}
          ]
        })
      ]

      opts = [strategy: :one_for_one, name: MyApp.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end
  ```

  Example hook registration using the `ProcessHub.Service.HookManager` module:
  ```elixir
  # Register a hook handler for the `:cluster_join` event with a wildcard argument.
  ProcessHub.Service.HookManager.register_hook(:my_hub, ProcessHub.Constant.Hook.cluster_join(), {MyModule, :my_function, [:some_data, :_]})
  ```

  Example hook handler:
  ```elixir
  # The hook handler should be in the following format:
  defmodule MyModule do
    def my_function(:some_data, dynamic_hook_data) do
      # Do something with the data.
    end
  end
  ```

  ### Available hooks
  | Event Key                        | Trigger                             | Data                                |
  | -------------------------------- | ----------------------------------- | ----------------------------------- |
  | `cluster_join_hook`              | Node joins the cluster              | `node()`                            |
  | `cluster_leave_hook`             | Node leaves the cluster             | `node()`                            |
  | `registry_pid_inserted_hook`     | Process registered                  | `{child_id(), [{node(), pid()}]}`   |
  | `registry_pid_removed_hook`      | Process unregistered                | `child_id()`                        |
  | `child_migrated_hook`            | Process migrated                    | `{child_id(), node()}`              |
  | `priority_state_updated_hook`    | Priority state updated              | `{priority_level(), list()}`        |
  | `pre_nodes_redistribution_hook`  | Nodes redistribution start          | `{:nodeup or :nodedown, node()}`    |
  | `post_nodes_redistribution_hook` | Nodes redistribution end            | `{:nodeup or :nodedown, node()}`    |
  | `forwarded_migration_hook`       | Migration was forwarded and handled | `{child_id(), node()}`              |

  See `ProcessHub.Constant.Hook` module for more information.

  ## Contributing
  Contributions are welcome and appreciated. If you have any ideas, suggestions, or bugs to report,
  please open an issue or a pull request on GitHub.
  """

  @typedoc """
  The `hub_id` defines the name of the hub. It is used to identify the hub.
  """
  @type hub_id() :: atom()

  @typedoc """
  The `child_id` defines the name of the child. It is used to identify the child.
  Each child must have a unique `child_id()` in the cluster. A single child may have
  multiple `pid()`s across the cluster.
  """
  @type child_id() :: atom() | binary()

  @typedoc """
  The `reply_to` defines the `pid()`s that will receive the response from the hub
  when a child is started or stopped.
  """
  @type reply_to() :: [pid()]

  @typedoc """
  The `child_spec` defines the specification of a child process.
  """
  @type child_spec() :: %{
          id: child_id(),
          start: {module(), atom(), [any()]}
        }

  @typedoc """
  The `init_opts()` defines the options that can be passed to the `start_children/3`, `start_child/3`,
  `stop_children/3`, and `stop_child/3` functions.

  - `:async_wait` - is optional and is used to define whether the function should return another function that
  can be used to wait for the children to start or stop. The default is `false`.
  - `:timeout` is optional and is used to define the timeout for the function. The timeout option
  should be used with `async_wait: true`. The default is `5000` (5 seconds).
  - `:check_mailbox` - is optional and is used to define whether the function should clear
  the mailbox of any existing messages that may overlap. It is recommended to keep this
  option `true` to avoid any unexpected behavior where `start_child/3` or `start_children/3`
  call timeout but eventually the calling process receives the start responses later. These messages
  will stay in that process's mailbox, and when the same process calls start child functions again with the
  same `child_id()`s, it will receive the old responses.This option should be used with `async_wait: true`.
   The default is `true`.
  - `:check_existing` - is optional and is used to define whether the function should check if the children
  are already started. The default is `true`.
  """
  @type init_opts() :: [
          async_wait: boolean(),
          timeout: non_neg_integer(),
          check_mailbox: boolean(),
          check_existing: boolean()
        ]

  @typedoc """
  The `stop_opts()` defines the options that can be passed to the `stop_children/3` and `stop_child/3` functions.

  - `:async_wait` - is optional and is used to define whether the function should return another function that
  can be used to wait for the children to stop. The default is `false`.
  - `:timeout` is optional and is used to define the timeout for the function. The timeout option
  should be used with `async_wait: true`. The default is `5000` (5 seconds).
  """
  @type stop_opts() :: [
          async_wait: boolean(),
          timeout: non_neg_integer()
        ]

  @typedoc """
  This is the base configuration structure for the hub and has to be passed to the `start_link/1` function.
  - `:hub_id` is the name of the hub and is required.
  - `:hooks` are optional and are used to define the hooks that can be triggered on specific events.
  - `:redundancy_strategy` is optional and is used to define the strategy for redundancy.
  The default is `ProcessHub.Strategy.Redundancy.Singularity`.
  - `:migration_strategy` is optional and is used to define the strategy for migration.
  The default is `ProcessHub.Strategy.Migration.ColdSwap`.
  - `:synchronization_strategy` is optional and is used to define the strategy for synchronization.
  The default is `ProcessHub.Strategy.Synchronization.PubSub`.
  - `:partition_tolerance_strategy` is optional and is used to define the strategy for partition tolerance.
  The default is `ProcessHub.Strategy.PartitionTolerance.Divergence`.
  """
  @type t() :: %__MODULE__{
          hub_id: hub_id(),
          hooks: ProcessHub.Service.HookManager.hooks(),
          redundancy_strategy:
            ProcessHub.Strategy.Redundancy.Singularity.t()
            | ProcessHub.Strategy.Redundancy.Replication.t(),
          migration_strategy:
            ProcessHub.Strategy.Migration.ColdSwap.t() | ProcessHub.Strategy.Migration.HotSwap.t(),
          synchronization_strategy:
            ProcessHub.Strategy.Synchronization.PubSub.t()
            | ProcessHub.Strategy.Synchronization.Gossip.t(),
          partition_tolerance_strategy:
            ProcessHub.Strategy.PartitionTolerance.Divergence.t()
            | ProcessHub.Strategy.PartitionTolerance.StaticQuorum.t()
            | ProcessHub.Strategy.PartitionTolerance.DynamicQuorum.t(),
          distribution_strategy: ProcessHub.Strategy.Distribution.ConsistentHashing.t()
        }

  @enforce_keys [:hub_id]
  defstruct [
    :hub_id,
    hooks: %{},
    redundancy_strategy: %ProcessHub.Strategy.Redundancy.Singularity{},
    migration_strategy: %ProcessHub.Strategy.Migration.ColdSwap{},
    synchronization_strategy: %ProcessHub.Strategy.Synchronization.PubSub{},
    partition_tolerance_strategy: %ProcessHub.Strategy.PartitionTolerance.Divergence{},
    distribution_strategy: %ProcessHub.Strategy.Distribution.ConsistentHashing{}
  ]

  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.State
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Utility.Name

  # 5 seconds
  @timeout 10000

  @doc """
  Starts a child process that will be distributed across the cluster.
  The `t:child_spec()` `:id` must be unique.

  ## Example
      iex> child_spec = %{id: :my_child, start: {MyProcess, :start_link, []}}
      iex> ProcessHub.start_child(:my_hub, child_spec)
      {:ok, :start_initiated}

  By default, the `start_child/3` function is **asynchronous** and returns immediately.
  To wait for the child to start, you can pass `async_wait: true` to the `opts` argument.
  When `async_wait: true`, you **must await** the response from the function.

  See `t:init_opts/0` for more options.

  ## Example with synchronous wait
  The synchronous response includes the status code `:ok` or `:error`, a tuple containing the `t:child_id/0` and
  a list of tuples where the first key is the node where the child is started, and the second key is the
  `pid()` of the started child. By default, the list should contain only one tuple, but if the
  redundancy strategy is configured for replicas, it may contain more than one tuple.

      iex> child_spec = %{id: :my_child, start: {MyProcess, :start_link, []}}
      iex> ProcessHub.start_child(:my_hub, child_spec, [async_wait: true]) |> ProcessHub.await()
      {:ok, {:my_child, [{:mynode, #PID<0.123.0>}]}}
  """
  @spec start_child(hub_id(), child_spec(), init_opts()) ::
          (-> {:ok, list})
          | {:error, :no_children | {:already_started, [atom | binary, ...]}}
          | {:ok, :start_initiated}
  def start_child(hub_id, child_spec, opts \\ []) do
    start_children(hub_id, [child_spec], Keyword.put(opts, :return_first, true))
  end

  @doc """
  Starts multiple child processes that will be distributed across the cluster.

  Same as `start_child/3`, except it starts multiple children at once and is more
  efficient than calling `start_child/3` multiple times.

  > #### Warning {: .warning}
  >
  > Using `start_children/3` with `async_wait: true` can lead to timeout errors,
  > especially when the number of children is large.
  """
  @spec start_children(hub_id(), [child_spec()], init_opts()) ::
          (-> {:ok, list})
          | {:ok, :start_initiated}
          | {:error,
             :no_children
             | {:error, :children_not_list}
             | {:already_started, [atom | binary, ...]}}
  def start_children(hub_id, child_specs, opts \\ []) when is_list(child_specs) do
    Distributor.init_children(hub_id, child_specs, default_init_opts(opts))
  end

  @doc """
  Stops a child process in the cluster.

  By default, this function is **asynchronous** and returns immediately.
  You can wait for the child to stop by passing `async_wait: true` in the `opts` argument.
  When `async_wait: true`, you **must await** the response from the function.

  ## Example
      iex> ProcessHub.stop_child(:my_hub, :my_child)
      {:ok, :stop_initiated}

  See `t:stop_opts/0` for more options.

  ## Example with synchronous wait
      iex> ProcessHub.stop_child(:my_hub, :my_child, [async_wait: true]) |> ProcessHub.await()
      {:ok, {:my_child, [:mynode]}}
  """
  @spec stop_child(hub_id(), child_id(), stop_opts()) ::
          (-> {:ok, list}) | {:ok, :stop_initiated}
  def stop_child(hub_id, child_id, opts \\ []) do
    stop_children(hub_id, [child_id], Keyword.put(opts, :return_first, true))
  end

  @doc """
  Stops multiple child processes in the cluster.

  This function is similar to `stop_child/3`, but it stops multiple children at once, making it more
  efficient than calling `stop_child/3` multiple times.

  > #### Warning {: .warning}
  >
  > Using `stop_children/3` with `async_wait: true` can lead to timeout errors,
  > especially when stopping a large number of child processes.
  """
  @spec stop_children(hub_id(), [child_id()], stop_opts()) ::
          (-> {:ok, list}) | {:ok, :stop_initiated} | {:error, list}
  def stop_children(hub_id, child_ids, opts \\ []) do
    Distributor.stop_children(hub_id, child_ids, default_init_opts(opts))
  end

  @doc """
  Works similarly to `Supervisor.which_children/1`, but wraps the result in a tuple
  containing the node name and the children.

  It's recommended to use `ProcessHub.process_registry/1` instead when fast lookups
  are required, as it makes no network calls.

  Available options:
  - `:global` - returns a list of all child processes started by all nodes in the cluster.
    The return result will be in the format of `[{:node, children}]`.
  - `:local` - returns a list of all child processes started by the local node.
    The return result will be in the format of `{:node, children}`.
  """
  @spec which_children(hub_id(), [:global | :local] | nil) ::
          list()
          | {node(),
             [{any, :restarting | :undefined | pid, :supervisor | :worker, :dynamic | list}]}
  def which_children(hub_id, opts \\ []) do
    case Enum.member?(opts, :global) do
      true -> Distributor.which_children_global(hub_id, opts)
      false -> Distributor.which_children_local(hub_id, opts)
    end
  end

  @doc """
  Checks if the `ProcessHub` with the given `t:hub_id/0` is alive.

  A hub is considered alive if the `ProcessHub.Initializer` supervisor process
  is running along with the required child processes for the hub to function.

  ## Example
      iex> ProcessHub.is_alive?(:not_existing)
      false
  """
  @spec is_alive?(hub_id()) :: boolean
  def is_alive?(hub_id) do
    pname = Name.initializer(hub_id)

    case Process.whereis(pname) do
      nil -> false
      _ -> true
    end
  end

  @doc """
  This function can be used to wait for the `ProcessHub` child start or stop
  functions to complete.

  The `await/1` function should be used with the `async_wait: true` option.

  Keep in mind that the `await/1` function will block the calling process until
  the response is received. If the response is not received within the timeout
  period, the function will return `{:error, term()}`.

  ## Example
      iex> ref = ProcessHub.start_child(:my_hub, child_spec, [async_wait: true])
      iex> ProcessHub.await(ref)
      {:ok, {:my_child, [{:mynode, #PID<0.123.0>}]}}
  """
  @spec await(function()) :: term()
  def await(init_func) when is_function(init_func) do
    init_func.()
  end

  def await(init_func), do: init_func

  @doc """
  Returns the child specification for the `ProcessHub.Initializer` supervisor.
  """
  @spec child_spec(t()) :: %{
          id: ProcessHub,
          start: {ProcessHub.Initializer, :start_link, [...]},
          type: :supervisor
        }
  def child_spec(opts) do
    %{
      id: opts.hub_id,
      start: {ProcessHub.Initializer, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts the `ProcessHub` with the given `t:hub_id/0` and settings.

  It is recommended to start the `ProcessHub` under a supervision tree.
  """
  @spec start_link(ProcessHub.t()) :: {:ok, pid()} | {:error, term()}
  defdelegate start_link(hub_settings), to: ProcessHub.Initializer, as: :start_link

  @doc """
  Stops the `ProcessHub` with the given `t:hub_id/0`.
  """
  @spec stop(atom) :: :ok | {:error, :not_alive}
  defdelegate stop(hub_id), to: ProcessHub.Initializer, as: :stop

  @doc """
  Returns information about processes that are registered with the given `t:child_id/0`.

  This function queries results from the local `ets` table and does not make any network calls.

  The return results contain the `t:child_spec/0` and a list of tuples where the first element is the node
  where the child is started, and the second element is the `pid()` of the started child.

  ## Example
      iex> {} = {_child_spec, _node_pid_tuples} = ProcessHub.child_lookup(:my_hub, :my_child)
      {%{id: :my_child, start: {MyProcess, :start_link, []}}, [{:mynode, #PID<0.123.0>}]}
  """
  @spec child_lookup(hub_id(), child_id()) :: {child_spec(), [{node(), pid()}]} | nil
  defdelegate child_lookup(hub_id, child_id), to: ProcessRegistry, as: :lookup

  @doc """
  Returns all information registered regarding the child processes.

  This function queries results from the local `ets` table and does not make any network calls.
  """
  @spec process_registry(hub_id()) :: ProcessHub.Service.ProcessRegistry.registry()
  defdelegate process_registry(hub_id), to: ProcessRegistry, as: :registry

  @doc """
  Checks if the `ProcessHub` with the given `t:hub_id/0` is locked.

  A hub is considered locked if the `ProcessHub` local event queue has a priority level
  greater than or equal to 10. This is used to throttle the hub from processing
  any new events and conserve data integrity.

  ## Example
      iex> ProcessHub.is_locked?(:my_hub)
      false
  """
  @spec is_locked?(hub_id()) :: boolean()
  defdelegate is_locked?(hub_id), to: State

  @doc """
  Checks if the `ProcessHub` with the given `t:hub_id/0` is in a network-partitioned state.

  A hub is considered partitioned if the `ProcessHub.Strategy.PartitionTolerance` strategy
  has detected a network partition. When a network partition is detected, the hub will
  terminate the `ProcessHub.DistributedSupervisor` process along with its children.

  ## Example
      iex> ProcessHub.is_partitioned?(:my_hub)
      false
  """
  @spec is_partitioned?(hub_id()) :: boolean()
  defdelegate is_partitioned?(hub_id), to: State

  @doc """
  Returns a list of nodes where the `ProcessHub` with the given `t:hub_id/0` is running.

  Nodes where the `ProcessHub` is running with the same `t:hub_id/0` are considered
  to be part of the same cluster.

  ## Example
      iex> ProcessHub.nodes(:my_hub, [:include_local])
      [:remote_node]
  """
  @spec nodes(hub_id(), [:include_local] | nil) :: [node()]
  defdelegate nodes(hub_id, opts \\ []), to: Cluster

  defp default_init_opts(opts) do
    Keyword.put_new(opts, :timeout, @timeout)
    |> Keyword.put_new(:async_wait, false)
    |> Keyword.put_new(:check_mailbox, true)
    |> Keyword.put_new(:check_existing, true)
    |> Keyword.put_new(:return_first, false)
  end
end
