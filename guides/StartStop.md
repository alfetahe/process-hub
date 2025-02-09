# Starting and stopping processes

The `ProcessHub` library provides a way to start and stop processes dynamically. 
The processes can be started under a hub and can be stopped at any time.

`ProcessHub` can be used with any process as long as it returns `{:ok, pid}` when started. We recommend using `GenServer` for the processes as it provides a lot of features out of the box.

## Process identification
The `:id` of child specification is used to uniquely identify the process in the hub and can be used to stop the process or query its `pid`.
The `:id` has to be either an **atom** or a **string**. For systems that create lots of dynamic processes, it is recommended to use strings as `:id` because atoms are not garbage collected. 

The `:id` has to be unique within the hub. If a process with the same `:id` is started again it may result in an unexpected behavior unless the uniqueness is checked before starting the process using the `:check_existing` option.

## Starting processes
Processes can be started dynamically using the `ProcessHub.start_children/3` or `ProcessHub.start_child/3` functions.
The latter is a convenience function to start a single process and wraps the former.

Some examples of starting processes are:

### Starting multiple processes
```elixir
iex> ProcessHub.start_children(:my_hub, [
  %{id: "process1", start: {MyProcess, :start_link, []}},
  %{id: "process2", start: {MyProcess, :start_link, []}}
])
{:ok, :start_initiated}
```

### Starting a single process
```elixir
child_spec = %{id: "process_id", start: {MyProcess, :start_link, []}}
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
            start: {MyProcess, :start_link, []}
        },
        %{
            id: :my_process_2,
            start: {MyProcess, :start_link, []}
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

## Stoping processes
Processes can be stopped dynamically using the `ProcessHub.stop_child/3` function or `ProcessHub.stop_children/3` function.

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

### Self stopping processes
Processes can also stop themselves by sending exit signals to the linked processes (supervisor).
This is useful when the process has to stop itself based on some condition.

For processes to be eligible for self-stopping, they have to be started with a `:restart` option set to `:transient`

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

If the `:restart` option is anything other than `:transient` and the stop code is not either `shutdown`or `normal` the supervisor will try to **restart** the process when it stops.

## Asynchronous operations
All operations by default are asynchronous and can be made synchronous by passing the `async_wait: true` option. The same options works for starting and stopping processes.

### Example of synchronous operation
```elixir
ProcessHub.start_children(
    :my_hub, 
    [child_spec1], 
    async_wait: true # Add this option to be able to wait for the operation to complete
) |> ProcessHub.await() # Wait for the operation to complete
{:ok, {:my_child, [{:mynode, #PID<0.123.0>}]}}
```




