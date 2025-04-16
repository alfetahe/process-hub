defmodule ProcessHub do
  @moduledoc """
  This is the main public API module for the `ProcessHub` library and it is recommended to use
  only the functions defined in this module to interact with the `ProcessHub` library.

  ProcessHub is a library that distributes processes within the BEAM cluster. It is designed to
  be used as a building block for distributed applications that require process distribution
  and synchronization.
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
  @type child_spec() :: Supervisor.child_spec()

  @typedoc """
  The `init_opts()` defines the options that can be passed to the `start_children/3`, `start_child/3`,
  `stop_children/3`, and `stop_child/3` functions.

  - `:async_wait` - is optional and is used to define whether the function should return another function that
  can be used to wait for the children to start or stop. The default is `false`.
  - `:timeout` is optional and is used to define the timeout for the function. The timeout option
  should be used with `async_wait: true`. The default is `5000` (5 seconds).
  - `:check_existing` - is optional and is used to define whether the function should check if the children
  are already started. The default is `true`.
  - `:on_failure` - is optional and is used to define the action to take when the start operation fails.
  The default is `:continue` which will continue to start the next child. The other option is `:rollback`
  which will stop all the children that have been started.

  """
  @type init_opts() :: [
          async_wait: boolean(),
          timeout: non_neg_integer(),
          check_existing: boolean(),
          on_failure: :continue | :rollback
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
  for hubs to start the discovery process. The default is `60000` (1 minute).
  - `:deadlock_recovery_timeout` is optional and is used to define the timeout in milliseconds
  to recover from locked hub. Hub locking can happen for different reasons
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
    hubs_discover_interval: 60000,
    deadlock_recovery_timeout: 60000,
    storage_purge_interval: 15000,
    migr_base_timeout: 15000,
    dsup_max_restarts: 100,
    dsup_max_seconds: 4,
    dsup_shutdown_timeout: 60000
  ]

  alias ProcessHub.Service.Distributor
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Service.State
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Utility.Name

  # 10 seconds
  @default_init_timeout 10000

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
          {:ok, :start_initiated}
          | {:error, :no_children | {:already_started, [atom | binary, ...]}}
          | (-> {:ok, start_result()})
          | (-> {:error, start_failure()} | {:error, start_failure(), start_result(), :rollback})
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
  > When `async_wait: true`, you **must await** the response from the function.
  """
  @spec start_children(hub_id(), [child_spec()], init_opts()) ::
          {:ok, :start_initiated}
          | {:error,
             :no_children
             | {:error, :children_not_list}
             | {:already_started, [atom | binary, ...]}}
          | (-> {:ok, [start_result()]})
          | (-> {:error, [start_failure()], [start_result()]}
                | {:error, [start_failure()], [start_result()], :rollback})
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
          {:ok, :stop_initiated}
          | (-> {:ok, stop_result()})
          | (-> {:error, stop_failure()})
  def stop_child(hub_id, child_id, opts \\ []) do
    stop_children(hub_id, [child_id], Keyword.put(opts, :return_first, true))
  end

  @doc """
  Stops multiple child processes in the cluster.

  This function is similar to `stop_child/3`, but it stops multiple children at once, making it more
  efficient than calling `stop_child/3` multiple times.

  > #### Warning {: .info}
  >
  > Using `stop_children/3` with `async_wait: true` can lead to timeout errors,
  > especially when stopping a large number of child processes.
  """
  @spec stop_children(hub_id(), [child_id()], stop_opts()) ::
          {:ok, :stop_initiated}
          | {:error, list}
          | (-> {:ok, [stop_result()]})
          | (-> {:error, [stop_failure()], [stop_result()]})
  def stop_children(hub_id, child_ids, opts \\ []) do
    Distributor.stop_children(hub_id, child_ids, default_init_opts(opts))
  end

  @doc """
  Works similarly to `Supervisor.which_children/1`, but wraps the result in a tuple
  containing the node name and the children.

  > #### Info {: .info}
  >
  > The `Supervisor.which_children/1` function is known to consume a lot of memory
  > and this can affect performance. The problem is even more relevant when
  > using the `:global` option as it will make a network call to all nodes in the cluster.
  >
  > It is highly recommended to use `ProcessHub.process_list/2` instead.

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
  @spec await(function() | {:error, term()}) ::
          {:ok, [start_result() | stop_result()]}
          | {:error, {[start_failure() | stop_failure()], [start_result() | stop_result()]}}
          | {:error, {[start_failure() | stop_failure()], [start_result() | stop_result()]},
             :rollback}
  def await(func) when is_function(func) do
    func.()
  end

  def await({:error, msg}), do: {:error, msg}

  def await(_), do: {:error, :invalid_await_input}

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
      iex> {_child_spec, _node_pid_tuples} = ProcessHub.child_lookup(:my_hub, :my_child)
      {%{id: :my_child, start: {MyProcess, :start_link, []}}, [{:mynode, #PID<0.123.0>}]}
  """
  @spec child_lookup(hub_id(), child_id()) :: {child_spec(), [{node(), pid()}]} | nil
  defdelegate child_lookup(hub_id, child_id), to: ProcessRegistry, as: :lookup

  @doc """
  Returns all information in the registry.

  This function queries results from the local `ets` table and does not make any network calls.
  """
  @spec process_registry(hub_id()) :: ProcessHub.Service.ProcessRegistry.registry()
  defdelegate process_registry(hub_id), to: ProcessRegistry, as: :registry

  @doc """
  Returns a list of pids for the given child_id.

  ## Example
      iex> ProcessHub.get_pids(:my_hub, :my_child)
      [#PID<0.123.0>]
  """
  @spec get_pids(ProcessHub.hub_id(), ProcessHub.child_id()) :: [pid()]
  defdelegate get_pids(hub_id, child_id), to: ProcessRegistry, as: :get_pids

  @doc """
  Returns the first pid for the given child_id.

  Although the function can be handy to quickly get the pid of the child, it is
  not recommended to use with replication strategies as it will return the first pid only.

  ## Example
      iex> ProcessHub.get_pid(:my_hub, :my_child)
      #PID<0.123.0>
  """
  @spec get_pid(ProcessHub.hub_id(), ProcessHub.child_id()) :: pid() | nil
  defdelegate get_pid(hub_id, child_id), to: ProcessRegistry, as: :get_pid

  @doc """
  Returns a list of processes that are registered.

  The process list contains the `t:child_id/0` and depending on the scope
  option, it may contain the node and `pid()` of the child.

  This function queries results from the local `ets` table and does not make any network calls.

  Available options:
  - `:global` - returns a list of all child processes on all nodes in the cluster.
    The return result will be in the format of `[{child_id, [{:node, pid}]}]`.
  - `:local` - returns a list of child processes that belong to the local node.
    The return result will be in the format of `[{child_id, [pid]}]`
    but only the processes that belong to the local node will be returned.

  ## Example
      iex> ProcessHub.process_list(:my_hub, :global)
      [
        {:my_child1, [{:node1, #PID<0.123.0>}, {:node2, #PID<2.123.0>}]},
        {:my_child2, [{:node2, #PID<5.124.0>}]}
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

  @doc """
  Promotes the `ProcessHub` with the given `t:hub_id/0` to a node.

  This function should be used when the `ProcessHub` has been started in a
  non-node mode and you want to promote it to a node.

  The function will update all existing child processes
  on the registry to match the new node name.

  Optionally, you can pass the `node_name` argument to specify the name of the node.
  By default, the current node name will be used.
  """
  @spec promote_to_node(hub_id()) :: :ok | {:error, :not_alive}
  defdelegate promote_to_node(hub_id, node_name \\ node()), to: Cluster

  defp default_init_opts(opts) do
    Keyword.put_new(opts, :timeout, @default_init_timeout)
    |> Keyword.put_new(:async_wait, false)
    |> Keyword.put_new(:check_existing, true)
    |> Keyword.put_new(:return_first, false)
    |> Keyword.put_new(:on_failure, :continue)
  end
end
