# Starting and stopping processes

The `ProcessHub` library provides a way to start and stop processes dynamically. 
The processes can be started under a hub and can be stopped at any time.

`ProcessHub` can be used with any process as long as it returns `{:ok, pid}` when started. We recommend using `GenServer` for the processes as it provides a lot of features out of the box.

## Process identification
The `:id` of the child specification is used to uniquely identify the process in the hub and can be used to stop the process or query its `pid`.
The `:id` has to be either an **atom** or a **string**. For systems that create lots of dynamic processes, it is recommended to use strings as `:id` because atoms are not garbage collected. 

The `:id` has to be unique within the hub. If a process with the same `:id` is started again, it may result in unexpected behavior unless the uniqueness is checked before starting the process using the `:check_existing` option.

## Starting processes
Processes can be started dynamically using the `ProcessHub.start_children/3` or `ProcessHub.start_child/3` functions.
The latter is a convenience function to start a single process and wraps the former.

Some examples of starting processes are:

### Starting multiple processes
```elixir
iex> ProcessHub.start_children(:my_hub, [
  %{id: "process1", start: {MyProcess, :start_link, [nil]}},
  %{id: "process2", start: {MyProcess, :start_link, [nil]}}
])
{:ok, :start_initiated}
```

### Starting a single process
```elixir
child_spec = %{id: "process_id", start: {MyProcess, :start_link, [nil]}}
ProcessHub.start_child(:my_hub, child_spec)
{:ok, :start_initiated}
```

### Starting processes statically
Processes can also be started statically under the supervision tree. This is useful when the processes are known at compile time.

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    child_specs = [
        %{
            id: :my_process_1,
            start: {MyProcess, :start_link, [nil]}
        },
        %{
            id: :my_process_2,
            start: {MyProcess, :start_link, [nil]}
        }
    ]

    children = [
      ProcessHub.child_spec(%ProcessHub{
        hub_id: :my_hub,
        child_specs: child_specs
      })
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

See `ProcessHub.init_opts/0` for more information on the options that can be passed to the start functions.

## Stopping processes
Processes can be stopped dynamically using the `ProcessHub.stop_child/3` or `ProcessHub.stop_children/3` functions.

Some examples of stopping processes are:
```elixir
ProcessHub.stop_child(:my_hub, "child_id")
{:ok, :stop_initiated}
```

```elixir
ProcessHub.stop_children(:my_hub, ["child_id1", "child_id2"])
{:ok, :stop_initiated}
```

See `ProcessHub.stop_opts/0` for more information on the options that can be passed to the stop functions.

### Self-stopping processes
Processes can also stop themselves by sending exit signals to the linked processes (supervisor).
This is useful when the process has to stop itself based on some condition.

For processes to be eligible for self-stopping, they have to be started with a `:restart` option set to `:transient`.

If the `:restart` option is anything other than `:transient` and the stop code is not either `shutdown` or `normal`, the supervisor will try to **restart** the process when it stops.

This will also update the registry accordingly for all the nodes in the cluster. Keep in mind that the operation is **asynchronous**.

### Example self-stopping GenServer process
```elixir
child_spec1 = %{
      id: :self_shutdown_1,
      start: {Test.Helper.TestServer, :start_link, [%{name: :self_shutdown_1}]},
      restart: :transient # Set the restart option to transient
    }

ProcessHub.start_child(:my_hub, child_spec)

# In the process module
defmodule MyProcess do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil)
  end

  def init(_) do
    {:ok, nil}
  end

  def handle_info(msg, state) do
    {:stop, :normal, state} # Return the stop tuple
  end
end
```

## Asynchronous operations
All process starting and stopping operations are asynchronous by default and can be made synchronous by passing the `awaitable: true` option. 
By doing so, the operation returns a `ProcessHub.Future` struct that can be awaited.

### Example of starting a process and awaiting the result
```elixir
child_spec = %{
  id: "my_process_1",
  start: {MyProcess, :start_link, [nil]}
}
ProcessHub.start_children(:my_hub, [child_spec], awaitable: true) 
|> ProcessHub.Future.await()
%ProcessHub.StartResult{
  status: :ok,
  started: [{"my_process_1", ["node1@127.0.0.1": #PID<0.231.0>]}],
  errors: [],
  rollback: false
}
```
### Example of stopping a process and awaiting the result
```elixir
ProcessHub.stop_child(:my_hub, "my_process_1", awaitable: true)
|> ProcessHub.Future.await()
%ProcessHub.StopResult{
  status: :ok,
  stopped: [{"my_process_1", [:"node1@127.0.0.1"]}],
  errors: []
}
```

## Formatting and extracting information from the results

When using awaitable operations, ProcessHub returns `ProcessHub.StartResult` and `ProcessHub.StopResult` structs that contain detailed information about the operation. These structs provide both formatting functions and convenient accessor functions to extract specific information.

### StartResult API Functions

The `ProcessHub.StartResult` module provides several functions to extract information from start operation results:

#### Basic Information Extraction
```elixir
# Start processes and get the result
result = ProcessHub.start_children(:my_hub, [child_spec1, child_spec2], awaitable: true)
|> ProcessHub.Future.await()

# Check the overall status
ProcessHub.StartResult.status(result)
:ok

# Get all child IDs that were processed
ProcessHub.StartResult.cids(result)
["child1", "child2"]

# Get all errors that occurred
ProcessHub.StartResult.errors(result)
[]
```

#### Process and Node Information
```elixir
# Get the first PID from the first started process
ProcessHub.StartResult.pid(result)
#PID<0.123.0>

# Get all PIDs from all started processes
ProcessHub.StartResult.pids(result)
[#PID<0.123.0>, #PID<0.124.0>]

# Get the first node from the first started process
ProcessHub.StartResult.node(result)
:"node1@127.0.0.1"

# Get all unique nodes where processes were started
ProcessHub.StartResult.nodes(result)
[:"node1@127.0.0.1", :"node2@127.0.0.1"]

# Get the first started child entry (full details)
ProcessHub.StartResult.first(result)
{"child1", [{:"node1@127.0.0.1", #PID<0.123.0>}]}
```

### StopResult API Functions

The `ProcessHub.StopResult` module provides similar functions for stop operation results:

```elixir
# Stop processes and get the result
result = ProcessHub.stop_children(:my_hub, ["child1", "child2"], awaitable: true)
|> ProcessHub.Future.await()

# Check the overall status
ProcessHub.StopResult.status(result)
:ok

# Get all child IDs that were processed
ProcessHub.StopResult.cids(result)
["child1", "child2"]

# Get all errors that occurred
ProcessHub.StopResult.errors(result)
[]

# Get all unique nodes where processes were stopped
ProcessHub.StopResult.nodes(result)
[:"node1@127.0.0.1", :"node2@127.0.0.1"]

# Get the first stopped child entry
ProcessHub.StopResult.first(result)
{"child1", [:"node1@127.0.0.1"]}
```

### Chaining Operations

You can chain ProcessHub operations with await and result processing in a single pipeline:

```elixir
# Chain start operation with immediate formatting
{:ok, started_processes} = ProcessHub.start_children(:my_hub, [child_spec1, child_spec2], awaitable: true)
|> ProcessHub.Future.await()
|> ProcessHub.StartResult.format()

# Chain start operation with status checking
:ok = ProcessHub.start_child(:my_hub, child_spec, awaitable: true)
|> ProcessHub.Future.await()
|> ProcessHub.StartResult.status()

# Chain stop operation with child ID extraction
stopped_ids = ProcessHub.stop_children(:my_hub, ["child1", "child2"], awaitable: true)
|> ProcessHub.Future.await()
|> ProcessHub.StopResult.cids()
# ["child1", "child2"]

# Chain start operation with PID extraction
pids = ProcessHub.start_children(:my_hub, [child_spec1, child_spec2], awaitable: true)
|> ProcessHub.Future.await()
|> ProcessHub.StartResult.pids()
# [#PID<0.123.0>, #PID<0.124.0>]
```

### Pattern Matching on Result Structs

Both `StartResult` and `StopResult` are regular Elixir structs that can be pattern matched directly:

```elixir
# Pattern match on successful start
result = ProcessHub.start_children(:my_hub, [child_spec1, child_spec2], awaitable: true)
|> ProcessHub.Future.await()

case result do
  %ProcessHub.StartResult{status: :ok, started: started} ->
    IO.puts("Successfully started: #{inspect(started)}")
    
  %ProcessHub.StartResult{status: :error, errors: errors, started: started} ->
    IO.puts("Some failures: #{inspect(errors)}")
    IO.puts("Some successes: #{inspect(started)}")
end
```

### Format Functions

Both result types provide `format/1` functions that return tuple formats:

```elixir
ProcessHub.StartResult.format(result)
{:ok, [{"child1", [{:"node1@127.0.0.1", #PID<0.123.0>}]}]}

# For error cases with rollback
{:error, {[{"child1", :timeout}], [{"child2", [{:"node1@127.0.0.1", #PID<0.124.0>}]}]}, :rollback}

ProcessHub.StopResult.format(result)  
{:ok, [{"child1", [:"node1@127.0.0.1"]}]}

# For error cases
{:error, {[{"child1", :"node1@127.0.0.1", :not_found}], []}}
```
