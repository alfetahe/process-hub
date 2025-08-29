defmodule ProcessHub do
  @moduledoc """
  This is the main public API module for the `ProcessHub` library. It is recommended to use
  only the functions defined in this module to interact with the `ProcessHub` library.

  ProcessHub is a library that distributes processes within the BEAM cluster. It is designed to
  be used as a building block for distributed applications that require process distribution
  and synchronization across multiple nodes.
  """

  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Future

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
  @type child_spec() :: Supervisor.child_spec()

  @typedoc """
  Defines the metadata that can be passed to the child process when it is started.
  """
  @type child_metadata() :: %{
          :tag => String.t()
        }

  @typedoc """
  The `init_opts()` defines the options that can be passed to the `start_children/3`, `start_child/3`,
  `stop_children/3`, and `stop_child/3` functions.

  - `:awaitable` - is optional and can be used to specify if the returned value should be an awaitable struct `ProcessHub.Future.t()`.
  The awaitable struct provides a way to handle the result of the operation synchronously by passing it to the `ProcessHub.Future.await/1` function.
  - `:async_wait` - (**deprecated** use `:awaitable`) is optional and is used to define whether the function should return a function that
  can be used to wait for the children to start or stop. The default is `false`.
  - `:timeout` - is optional and is used to define the timeout for the function. This timeout option
  should be used with `async_wait: true`. The default is `5000` (5 seconds).
  - `:check_existing` - is optional and is used to define whether the function should check if the children
  are already started. The default is `true`.
  - `:on_failure` - is optional and is used to define the action to take when the start operation fails.
  The default is `:continue` which will continue to start the next child. The other option is `:rollback`
  which will stop all the children that have been started.
  - `:metadata` - is optional and is used to define the metadata that will be stored in the process registry
  when the child is started. The metadata can be used to store any information that is needed to identify
  the child process.
  - `:disable_logging` - is optional and is used to define whether logging should be disabled for the child process
  startup or shutdown. Mostly used for testing purposes.
  - `:await_timeout` - is optional and is used to define the maximum lifetime for the spawned collector process.
  After this time, the collector process will be terminated and attempts to collect the results using `ProcessHub.await/1` will fail.
  The await_timeout option should be used with `awaitable: true`. The default is `60000` (60 seconds).
  """
  @type init_opts() :: [
          awaitable: boolean(),
          async_wait: boolean(),
          timeout: non_neg_integer(),
          check_existing: boolean(),
          on_failure: :continue | :rollback,
          metadata: child_metadata(),
          disable_logging: boolean(),
          await_timeout: non_neg_integer()
        ]

  @typedoc """
  The `stop_opts()` defines the options that can be passed to the `stop_children/3` and `stop_child/3` functions.

  - `:awaitable` - is optional and can be used to specify if the returned value should be an awaitable struct `ProcessHub.Future.t()`.
  The awaitable struct provides a way to handle the result of the operation synchronously by passing it to the `ProcessHub.Future.await/1` function.
  - `:async_wait` - (**deprecated** use `:awaitable`) is optional and is used to define whether the function should return a function that
  can be used to wait for the children to stop. The default is `false`.
  - `:timeout` - is optional and is used to define the maximum time for the function to complete.
  This timeout option should be used with `async_wait: true`. The default is `5000` (5 seconds).
  - `:await_timeout` - is optional and is used to define the maximum lifetime for the spawned collector process.
  After this time, the collector process will be terminated and attempts to collect the results using `ProcessHub.await/1` will fail.
  The await_timeout option should be used with `awaitable: true`. The default is `60000` (60 seconds).
  """
  @type stop_opts() :: [
          awaitable: boolean(),
          async_wait: boolean(),
          timeout: non_neg_integer(),
          await_timeout: non_neg_integer()
        ]

  @typedoc """
  Defines the success result for a single child start operation.
  """
  @type start_result() :: {child_id(), [{node(), pid()}]}

  @typedoc """
  Defines the failure result for a single child start operation.

  The `term()` can be any term that describes the failure reason.
  """
  @type start_failure() :: {child_id(), node(), term()}

  @typedoc """
  Defines the success result for a single child stop operation.
  """
  @type stop_result() :: {child_id(), [node()]}

  @typedoc """
  Defines the failure result for a single child stop operation.

  The `term()` can be any term that describes the failure reason.
  """
  @type stop_failure() :: {child_id(), [term()]}

  @typedoc """
  This is the base configuration structure for the hub and has to be passed to the `start_link/1` function.
  - `:hub_id` is the name of the hub and is required.
  - `:child_specs` is optional and is used to define the child processes that will be started with the hub statically.
  - `:hooks` are optional and are used to define the hooks that can be triggered on specific events.
  - `:redundancy_strategy` is optional and is used to define the strategy for redundancy.
  The default is `ProcessHub.Strategy.Redundancy.Singularity`.
  - `:migration_strategy` is optional and is used to define the strategy for migration.
  The default is `ProcessHub.Strategy.Migration.ColdSwap`.
  - `:synchronization_strategy` is optional and is used to define the strategy for synchronization.
  The default is `ProcessHub.Strategy.Synchronization.PubSub`.
  - `:partition_tolerance_strategy` is optional and is used to define the strategy for partition tolerance.
  The default is `ProcessHub.Strategy.PartitionTolerance.Divergence`.
  - `:distribution_strategy` is optional and is used to define the strategy for process distribution.
  The default is `ProcessHub.Strategy.Distribution.ConsistentHashing`.
  - `:hubs_discover_interval` is optional and is used to define the interval in milliseconds
  for hubs to start the discovery process. The default is `30000` (30 seconds).
  - `:deadlock_recovery_timeout` is optional and is used to define the timeout in milliseconds
  to recover from a locked hub. Hub locking can happen for different reasons
  such as updating internal data, migrating processes or handling network partitions.
  The default is `60000` (1 minute).
  - `:storage_purge_interval` is optional and is used to define the interval in milliseconds
  for the janitor to clean up the old cache records when the TTL expires. The default is `15000` (15 seconds).
  - `:migr_base_timeout` is optional and is used to define the base timeout in milliseconds
  for the migration process to complete before the hub considers it as a failure.
  The default is `15000` (15 seconds).
  - `:dsup_max_restarts` is optional and is used to define the maximum number of restarts
  for the distributed supervisor. See `Supervisor` child specification for more information.
  The default is `100`.
  - `:dsup_max_seconds` is optional and is used to define the maximum number of seconds
  for the distributed supervisor to restart the child process.
  See `Supervisor` child specification for more information. The default is `4`.
  - `:dsup_shutdown_timeout` is optional and is used to define the timeout in milliseconds
  for the distributed supervisor to wait before forcefully terminating itself
  when receiving a shutdown signal.
  """
  @type t() :: %__MODULE__{
          hub_id: hub_id(),
          child_specs: [child_spec()],
          hooks: ProcessHub.Service.HookManager.hook_handlers(),
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
          distribution_strategy:
            ProcessHub.Strategy.Distribution.ConsistentHashing.t()
            | ProcessHub.Strategy.Distribution.Guided.t(),
          hubs_discover_interval: pos_integer(),
          deadlock_recovery_timeout: pos_integer(),
          storage_purge_interval: pos_integer(),
          migr_base_timeout: pos_integer(),
          dsup_max_restarts: pos_integer(),
          dsup_max_seconds: pos_integer(),
          dsup_shutdown_timeout: pos_integer()
        }

  @enforce_keys [:hub_id]
  defstruct [
    :hub_id,
    child_specs: [],
    hooks: %{},
    redundancy_strategy: %ProcessHub.Strategy.Redundancy.Singularity{},
    migration_strategy: %ProcessHub.Strategy.Migration.ColdSwap{},
    synchronization_strategy: %ProcessHub.Strategy.Synchronization.PubSub{},
    partition_tolerance_strategy: %ProcessHub.Strategy.PartitionTolerance.Divergence{},
    distribution_strategy: %ProcessHub.Strategy.Distribution.ConsistentHashing{},
    hubs_discover_interval: 10000,
    deadlock_recovery_timeout: 60000,
    storage_purge_interval: 15000,
    migr_base_timeout: 15000,
    dsup_max_restarts: 100,
    dsup_max_seconds: 4,
    dsup_shutdown_timeout: 60000
  ]

  @doc """
  Starts a single child process that will be distributed across the cluster based on the configured distribution strategy.

  The child process will be started on one or more nodes in the cluster depending on the redundancy configuration.
  The `t:child_spec()` `:id` field must be unique across the entire cluster.

  ## Basic Usage
      iex> child_spec = %{id: :my_child, start: {MyProcess, :start_link, [nil]}}
      iex> ProcessHub.start_child(:my_hub, child_spec)
      {:ok, :start_initiated}

  By default, the `start_child/3` function is **asynchronous** and returns immediately with a confirmation
  that the start operation has been initiated. The actual child process startup happens in the background.

  To wait for the child to start and get detailed results, you can pass `awaitable: true` to the `opts` argument and
  use the `ProcessHub.Future.await/1` function on the returned future.

  See `t:init_opts/0` for all available options including timeout control, failure handling, and metadata.

  ## Synchronous Operation Example
  When using the awaitable option, you get detailed information about the startup process including
  the final status, started processes with their PIDs and node locations, any errors encountered,
  and rollback information if applicable.

      iex> child_spec = %{id: "my_child", start: {MyProcess, :start_link, [nil]}}
      iex> future = ProcessHub.start_child(:my_hub, child_spec, [awaitable: true])
      {
        :ok,
        %ProcessHub.Future{
          future_resolver: #PID<0.253.0>,
          ref: #Reference<0.717952655.487849985.214641>,
          timeout: 60000
        }
      }

      # Wait for the child to start and get the result.
      iex> ProcessHub.Future.await(future)
      %ProcessHub.StartResult{
        status: :ok,
        started: [{"my_child", ["node2@127.0.0.1": #PID<23618.225.0>]}],
        errors: [],
        rollback: false
      }

      # Get the status.
      iex> ProcessHub.StartResult.status(result)
      :ok

      # Get the pid.
      iex> ProcessHub.StartResult.pid(result)
      #PID<23618.225.0>

  > #### Handling startup results {: .info}
  >
  > See more about how to handle startup results at [Starting and stopping processes](startstop.html#startresult-api-functions)
  """
  @spec start_child(hub_id(), child_spec(), init_opts()) ::
          {:ok, :start_initiated}
          | {:ok, Future.t()}
          | {:error, :no_children | {:already_started, [atom | binary, ...]}}
  def start_child(hub_id, child_spec, opts \\ []) do
    start_children(hub_id, [child_spec], Keyword.put(opts, :return_first, true))
  end

  @doc """
  Starts multiple child processes that will be distributed across the cluster.

  This function works similarly to `start_child/3`, but it handles multiple children simultaneously,
  making it much more efficient than calling `start_child/3` multiple times. Each child process
  will be distributed according to the configured distribution strategy.

  All child specifications must have unique `:id` fields across the entire cluster.

  See `t:init_opts/0` for all available options including failure handling strategies.

  ## Examples
      iex> child_specs = [
      iex>  %{id: "child1", start: {MyProcess, :start_link, [nil]}},
      iex>  %{id: "child2", start: {MyProcess, :start_link, [nil]}}
      iex> ]
      iex> # Start the child processes.
      iex> future = ProcessHub.start_children(:my_hub, child_specs, [awaitable: true])
      {
        :ok,
        %ProcessHub.Future{
          future_resolver: #PID<0.222.0>,
          ref: #Reference<0.2401267543.3981705217.217572>,
          timeout: 60000
        }
      }

      iex> # Wait for the children to start and get the result.
      iex> result = ProcessHub.Future.await(future)
      %ProcessHub.StartResult{
        status: :ok,
        started: [
          {"child2", ["node1@127.0.0.1": #PID<0.237.0>]},
          {"child1", ["node1@127.0.0.1": #PID<0.236.0>]}
        ],
        errors: [],
        rollback: false
      }

      iex> # Get the pids.
      iex> ProcessHub.StartResult.pids(result)
      [#PID<0.237.0>, #PID<0.236.0>]

  > #### Handling startup results {: .info}
  >
  > See more about how to handle startup results at [Starting and stopping processes](startstop.html#startresult-api-functions)

  > #### Warning {: .warning}
  >
  > Using `start_children/3` with `awaitable: true` can lead to timeout errors,
  > especially when the number of children is large.

  """
  @spec start_children(hub_id(), [child_spec()], init_opts()) ::
          {:ok, :start_initiated}
          | {:ok, Future.t()}
          | {:error,
             :no_children
             | {:error, :children_not_list}
             | {:already_started, [atom | binary, ...]}}
  def start_children(hub_id, child_specs, opts \\ []) when is_list(child_specs) do
    GenServer.call(hub_id, {:init_children_start, child_specs, opts})
  end

  @doc """
  Stops a single child process across the entire cluster.

  This function will terminate the specified child process on all nodes where it is currently running.
  By default, this function is **asynchronous** and returns immediately with a confirmation
  that the stop operation has been initiated. The actual process termination happens in the background.

  To wait for the child to stop and get detailed results about the termination, you can pass 
  `awaitable: true` in the `opts` argument and use the `ProcessHub.Future.await/1` function 
  on the returned future.

  ## Basic Usage
      iex> ProcessHub.stop_child(:my_hub, :my_child)
      {:ok, :stop_initiated}

  See `t:stop_opts/0` for all available options including timeout control.

  ## Example with synchronous wait
      iex> ProcessHub.stop_child(:my_hub, "child1", [awaitable: true]) |> ProcessHub.Future.await()
      %ProcessHub.StopResult{
        status: :ok,
        stopped: [{"child1", [:"node1@127.0.0.1"]}],
        errors: []
      }

  > #### Handling stop results {: .info}
  >
  > See more about how to handle stop results at [Starting and stopping processes](startstop.html#stopresult-api-functions)
  """
  @spec stop_child(hub_id(), child_id(), stop_opts()) ::
          {:ok, :stop_initiated} | {:ok, Future.t()}
  def stop_child(hub_id, child_id, opts \\ []) do
    stop_children(hub_id, [child_id], Keyword.put(opts, :return_first, true))
  end

  @doc """
  Stops multiple child processes across the entire cluster.

  This function works similarly to `stop_child/3`, but handles multiple children simultaneously,
  making it much more efficient than calling `stop_child/3` multiple times. Each specified
  child process will be terminated on all nodes where it is currently running.

  See `t:stop_opts/0` for all available options including timeout control.

  ## Examples

      iex> ProcessHub.stop_children(:my_hub, ["child1", "child2"], [])
      {:ok, :stop_initiated}

  > #### Warning {: .warning}
  >
  > Using `stop_children/3` with `awaitable: true` can lead to timeout errors
  > when stopping a large number of child processes.

  > #### Handling stop results {: .info}
  >
  > See more how to handle stop results at [Starting and stopping processes](startstop.html#stopresult-api-functions)
  """
  @spec stop_children(hub_id(), [child_id()], stop_opts()) ::
          {:ok, :stop_initiated}
          | {:ok, Future.t()}
          | {:error, list()}
  def stop_children(hub_id, child_ids, opts \\ []) do
    GenServer.call(hub_id, {:init_children_stop, child_ids, opts})
  end

  @doc """
  Returns information about child processes in a format similar to `Supervisor.which_children/1`,
  but wraps the result in a tuple containing the node name and the children.

  > #### Performance Warning {: .warning}
  >
  > The `Supervisor.which_children/1` function is known to consume a lot of memory
  > and can significantly affect performance. This problem is even more relevant when
  > using the `:global` option, as it will make network calls to all nodes in the cluster.
  >
  > It is **highly recommended** to use `ProcessHub.process_list/2` instead, which is more efficient.

  ## Available Options:
  - `:global` - returns a list of all child processes started by all nodes in the cluster.
    The return result will be in the format of `[{:node, children}]`.
  - `:local` - returns a list of all child processes started by the local node.
    The return result will be in the format of `{:node, children}`.
  """
  @deprecated "Will be removed from the next minor release. Use `ProcessHub.process_list/2` instead."
  @spec which_children(hub_id(), [:global | :local] | nil) ::
          list()
          | {node(),
             [{any, :restarting | :undefined | pid, :supervisor | :worker, :dynamic | list}]}
  def which_children(hub_id, opts \\ []) do
    GenServer.call(hub_id, {:get_dist_children, opts})
  end

  @doc """
  Checks if a `ProcessHub` instance with the given `t:hub_id/0` is currently alive and operational.

  A hub is considered alive if the `ProcessHub.Coordinator` process is
  running and the hub is ready to handle requests and manage processes.

  ## Example
      iex> ProcessHub.is_alive?(:not_existing)
      false
  """
  @spec is_alive?(hub_id()) :: boolean
  def is_alive?(hub_id) do
    case Process.whereis(hub_id) do
      nil -> false
      _ -> true
    end
  end

  @deprecated "Use `ProcessHub.Future.await/1` instead. The implementation of this function will be replaced in the 0.5.x version. The `:rollback` option does not work with this function."
  @doc """
  This function can be used to wait for the `ProcessHub` child start or stop
  functions to complete.

  The `await/1` function should only be used with the `async_wait: true` option.

  Keep in mind that the `await/1` function will block the calling process until
  the response is received. If the response is not received within the timeout
  period, the function will return `{:error, term()}`.

  ## Example
      iex> {:ok, future} = ProcessHub.start_child(:my_hub, child_spec, [async_wait: true])
      iex> ProcessHub.await(future)
      {:ok, {:my_child, [{:mynode, #PID<0.123.0>}]}}
  """
  @spec await(Future.t() | {:ok, Future.t()} | {:error, term()} | term()) ::
          {:ok, start_result() | [start_result() | stop_result()]}
          | {:error, {[start_failure() | stop_failure()], [start_result() | stop_result()]}}
          | {:error, {[start_failure() | stop_failure()], [start_result() | stop_result()]},
             :rollback}
  def await({:ok, future}) when is_struct(future) do
    Future.await(future)
  end

  def await(future) when is_struct(future) do
    Future.await(future)
  end

  def await({:error, msg}), do: {:error, msg}

  def await(_), do: {:error, :invalid_await_input}

  @doc """
  Returns the child specification for the `ProcessHub.Initializer` supervisor.

  This function generates the proper supervisor child specification needed to start
  a ProcessHub instance under a supervision tree. The returned specification follows
  the standard Supervisor child_spec format and can be used directly in supervisor
  child lists.

  ## Examples
      iex> ProcessHub.child_spec(%ProcessHub{hub_id: :my_hub})
      %{
        id: :my_hub,
        start: {
          ProcessHub.Initializer,
          :start_link,
          [
            %ProcessHub{
              hub_id: :my_hub,
              child_specs: [],
              hooks: %{},
              redundancy_strategy: %ProcessHub.Strategy.Redundancy.Singularity{},
              migration_strategy: %ProcessHub.Strategy.Migration.ColdSwap{},
              synchronization_strategy: %ProcessHub.Strategy.Synchronization.PubSub{
                sync_interval: 15000
              },
              partition_tolerance_strategy: %ProcessHub.Strategy.PartitionTolerance.Divergence{},
              distribution_strategy: %ProcessHub.Strategy.Distribution.ConsistentHashing{},
              hubs_discover_interval: 10000,
              deadlock_recovery_timeout: 60000,
              storage_purge_interval: 15000,
              migr_base_timeout: 15000,
              dsup_max_restarts: 100,
              dsup_max_seconds: 4,
              dsup_shutdown_timeout: 60000
            }
          ]
        },
        type: :supervisor
      }
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
  Starts a new `ProcessHub` instance with the specified configuration.

  This function initializes a complete ProcessHub system including the coordinator,
  distributed supervisor, and all necessary supporting processes. The hub will be
  ready to accept and manage child processes according to the configured strategies.

  It is **strongly recommended** to start the ProcessHub under a supervision tree
  to ensure proper fault tolerance and automatic restart capabilities.

  ## Example

      iex> ProcessHub.start_link(%ProcessHub{hub_id: :my_hub})
      {:ok, #PID<0.123.0>}
  """
  @spec start_link(ProcessHub.t()) :: {:ok, pid()} | {:error, term()}
  defdelegate start_link(hub_settings), to: ProcessHub.Initializer, as: :start_link

  @doc """
  Gracefully stops a running `ProcessHub` instance.

  This function will cleanly shut down the ProcessHub system, including terminating
  all managed child processes and cleaning up associated resources. The shutdown
  process follows proper OTP shutdown protocols.

  ## Example
      iex> ProcessHub.stop(:my_hub)
      :ok
  """
  @spec stop(atom) :: :ok | {:error, :not_alive}
  defdelegate stop(hub_id), to: ProcessHub.Initializer, as: :stop

  @doc """
  Returns detailed information about a specific child process registered with the given `t:child_id/0`.

  This function performs a fast local lookup by querying the local `ets` table and does not make
  any network calls. The lookup returns the original child specification and location information
  for all instances of the process across the cluster.

  The return value is a tuple containing the `t:child_spec/0` and a list of `{node, pid}` tuples
  indicating where the child process is running and its corresponding process ID.

  Optionally, you can pass the `with_metadata: true` option to include any metadata
  that was provided when the child process was started.

  ## Examples
      # Lookup a child process by its ID.
      iex> {child_spec, node_pids_tuples} = ProcessHub.child_lookup(:my_hub, "child1")
      {
        %{id: "child1", start: {MyProcess, :start_link, [nil]}},
        ["node1@127.0.0.1": #PID<0.1487.0>]
      }

      # Lookup a child process by its ID and include metadata.
      iex> {child_spec, node_pid_tuples, metadata} = ProcessHub.child_lookup(:my_hub, "child1", with_metadata: true)
      {
        %{id: "child1", start: {MyProcess, :start_link, [nil]}},
        ["node1@127.0.0.1": #PID<0.1487.0>],
        %{}
      }
  """
  @spec child_lookup(hub_id(), child_id(), with_metadata: boolean()) ::
          {child_spec(), [{node(), pid()}]} | nil
  defdelegate child_lookup(hub_id, child_id, opts \\ []), to: ProcessRegistry, as: :lookup

  @doc """
  Returns all processes that are registered with a specific tag.

  This function queries the process registry and returns all children that
  are registered with the given tag. This is particularly useful when you need
  to group and query processes by category or type using custom tags.

  To register a child with a tag, pass the `metadata` option to `start_child/3` or `start_children/3`
  with a `:tag` key containing the desired tag value.

  ## Example
      iex> ProcessHub.start_children(:my_hub, child_specs, [metadata: %{tag: "my_tag"}]) |> ProcessHub.Future.await()
      iex>
      iex> # get the processes by tag name.
      iex> ProcessHub.tag_query(:my_hub, "my_tag")
      [
        {:my_child, [{:mynode, #PID<0.123.0>}],
        {:my_child2, [{:mynode2, #PID<0.124.0>}]}
      ]
  """
  @spec tag_query(hub_id(), String.t()) :: [{child_id(), [{node(), pid()}]}]
  defdelegate tag_query(hub_id, tag), to: ProcessRegistry, as: :match_tag

  @doc """
  Dumps all information currently stored in the process registry.

  This function returns a comprehensive view of the registry, including child specifications,
  process IDs, node locations, and metadata for all registered processes. This is useful
  for debugging, monitoring, or administrative tasks where you need a complete overview
  of all managed processes in the hub.

  ## Example
      iex> ProcessHub.registry_dump(:my_hub)
      %{
        "child1" => {
          %{id: "child1", start: {MyProcess, :start_link, [nil]}},
          [
            "node1@127.0.0.1": #PID<0.1487.0>
          ],
          %{}
        },
        "child2" => {
          %{id: "child2", start: {MyProcess, :start_link, [nil]}},
          [
            "node1@127.0.0.1": #PID<0.1488.0>
          ],
          %{}
        }
      }
  """
  @spec registry_dump(hub_id()) :: ProcessHub.Service.ProcessRegistry.registry_dump()
  defdelegate registry_dump(hub_id), to: ProcessRegistry, as: :dump

  @doc """
  Returns all information stored in the process registry.

  This function performs a local query against the `ets` table and does not make any network calls.

  > #### Deprecation Notice {: .warning}
  >
  > This function is deprecated and will be removed in a future version.
  """
  @deprecated "Use `ProcessHub.registry_dump/1` instead"
  @spec process_registry(hub_id()) :: ProcessHub.Service.ProcessRegistry.registry()
  defdelegate process_registry(hub_id), to: ProcessRegistry, as: :registry

  @doc """
  Returns all process IDs (PIDs) for a specific child process.

  This function retrieves all PIDs associated with a given child ID across the cluster.
  If the child is running on multiple nodes (due to replication), all PIDs will be returned.

  ## Example
      iex> ProcessHub.get_pids(:my_hub, :my_child)
      [#PID<0.123.0>]
  """
  @spec get_pids(ProcessHub.hub_id(), ProcessHub.child_id()) :: [pid()]
  defdelegate get_pids(hub_id, child_id), to: ProcessRegistry, as: :get_pids

  @doc """
  Returns the first available process ID (PID) for a specific child process.

  This function provides a convenient way to quickly get a PID for a child process.
  However, when using replication strategies, this function will only return the first
  available PID, which may not be suitable for all use cases where you need to interact
  with all replicas.

  > #### Replication Warning {: .warning}
  >
  > When using replication strategies, consider using `get_pids/2` instead to get all PIDs.

  ## Example
      iex> ProcessHub.get_pid(:my_hub, :my_child)
      #PID<0.123.0>
  """
  @spec get_pid(ProcessHub.hub_id(), ProcessHub.child_id()) :: pid() | nil
  defdelegate get_pid(hub_id, child_id), to: ProcessRegistry, as: :get_pid

  @doc """
  Returns a list of all registered processes in the hub.

  This function provides an efficient way to enumerate all child processes managed by the hub.
  The returned list contains child IDs and, depending on the scope option, may include
  node locations and process IDs.

  This function performs a fast local query against the `ets` table and does not make any network calls.

  ## Available Options:
  - `:global` - returns a list of all child processes across all nodes in the cluster.
    The return result will be in the format of `[{child_id, [{:node, pid}]}]`.
  - `:local` - returns only child processes that are running on the local node.
    The return result will be in the format of `[{child_id, [pid]}]`.

  ## Example
      iex> ProcessHub.process_list(:my_hub, :global)
      [
        {:my_child1, [{:node1, #PID<0.123.0>}, {:node2, #PID<2.129.0>}]},
        {:my_child2, [{:node1, #PID<0.126.0>}, {:node2, #PID<2.124.0>}]}
      ]
      iex> ProcessHub.process_list(:my_hub, :local)
      [{:my_child1, #PID<0.123.0>}]
  """
  @spec process_list(hub_id(), :global | :local) :: [
          {ProcessHub.child_id(), [{node(), pid()}] | pid()}
        ]
  defdelegate process_list(hub_id, scope), to: ProcessRegistry, as: :process_list

  @doc """
  Checks if the `ProcessHub` with the given `t:hub_id/0` is locked.

  A hub is considered locked if the `ProcessHub` local event queue has a priority level
  greater than or equal to 10. This is used to throttle the hub from processing
  any new events and preserve data integrity.

  ## Example
      iex> ProcessHub.is_locked?(:my_hub)
      false
  """
  @spec is_locked?(hub_id()) :: boolean()
  def is_locked?(hub_id) do
    GenServer.call(hub_id, :is_locked?)
  end

  @doc """
  Checks if a `ProcessHub` instance with the given `t:hub_id/0` is currently in a network-partitioned state.

  A hub is considered partitioned when the configured `ProcessHub.Strategy.PartitionTolerance` strategy
  has detected a network partition event. When a network partition is detected, the hub will
  terminate the `ProcessHub.DistributedSupervisor` process along with all its managed child processes
  to maintain data consistency and prevent split-brain scenarios.

  ## Example
      iex> ProcessHub.is_partitioned?(:my_hub)
      false
  """
  @spec is_partitioned?(hub_id()) :: boolean()
  def is_partitioned?(hub_id) do
    GenServer.call(hub_id, :is_partitioned?)
  end

  @doc """
  Returns a list of all nodes where a `ProcessHub` instance with the given `t:hub_id/0` is currently running.

  All nodes running the same `ProcessHub` instance (identified by the same `t:hub_id/0`) are considered
  to be part of the same logical cluster and can coordinate process distribution and management.

  ## Options:
  - `[:include_local]` - includes the local node in the returned list (default: excludes local node)

  ## Example
      iex> ProcessHub.nodes(:my_hub, [:include_local])
      [:"node1@127.0.0.1", :"node2@127.0.0.1"]
  """
  @spec nodes(hub_id(), [:include_local] | nil) :: [node()]
  def nodes(hub_id, opts \\ []) do
    GenServer.call(hub_id, {:get_nodes, opts})
  end

  @doc """
  Promotes a `ProcessHub` instance to run in distributed node mode.

  This function should be used when the `ProcessHub` was initially started in
  non-distributed mode (for example, during development or testing) and you want
  to promote it to participate in a distributed cluster.

  The promotion process will update all existing child process registrations
  in the registry to reflect the new node name, ensuring proper cluster coordination.

  ## Parameters:
  - `node_name` (optional) - specifies the node name to use. If not provided,
    the current node name (`Node.self()`) will be used.
  """
  @spec promote_to_node(hub_id()) :: :ok | {:error, :not_alive}
  def promote_to_node(hub_id, node_name \\ node()) do
    GenServer.call(hub_id, {:promote_to_node, node_name})
  end

  # TODO: add tests.
  @doc """
  Dynamically registers hook handlers for specific hub events.

  Hook handlers allow you to execute custom logic when specific events occur
  within the ProcessHub lifecycle, such as process startup, shutdown, node joining,
  or cluster events. This provides a powerful extension mechanism for monitoring,
  logging, or custom business logic.

  ## Parameters:
  - `hub_id` - the hub to register handlers for
  - `hook_key` - the specific event type to handle (use `ProcessHub.Constant.Hook` constants)
  - `hook_handlers` - a list of `ProcessHub.Service.HookManager` structs defining the handlers

  ## Examples
      iex> ProcessHub.register_hook_handlers(
      iex>   :my_hub,
      iex>   ProcessHub.Constant.Hook.pre_cluster_join(),
      iex>   [
      iex>     %ProcessHub.Service.HookManager{
      iex>       id: :my_hook_id,
      iex>       m: SomeModule,
      iex>       f: :some_function,
      iex>       a: [:my_first_argument]
      iex>     }
      iex>   ]
      iex> )
      [:ok]

  """
  @spec register_hook_handlers(hub_id(), HookManager.hook_key(), [HookManager.t()]) ::
          :ok | {:error, {:handler_id_not_unique, [HookManager.handler_id()]}}
  def register_hook_handlers(hub_id, hook_key, hook_handlers) do
    GenServer.call(hub_id, {:register_hook_handlers, hook_key, hook_handlers})
  end
end
