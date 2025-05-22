# Process state handover

In this guide we will show a simple example of how to handover the state of a process from one node to another.

This scenario is happening automatically when the cluster has received new node event,
meaning that the new node has joined the cluster or left.

Suppose we have the following `GenServer` process:

```elixir
defmodule MyProcess do
  use GenServer

  def start_link(state) do
    GenServer.start_link(__MODULE__, state)
  end

  def init(state) do
    {:ok, state}
  end
end
```

In order to handover the state of the process from one node to another, we need to do the following:

### 1. Configure the hub 

Configure the `ProcessHub` to use the `Hotswap` strategy.

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
      migration_strategy: %ProcessHub.Strategy.Migration.HotSwap{
        retention: 3000,
        handover: true
      },
    }}
  end
end
```

Pay attention to the `retention` and `handover` options. The `retention` option is the max time in milliseconds that the old process will be kept alive when migrating. The `handover` option is a boolean that indicates whether the process state should be handed over to another node when the process is going to be stopped.

The HotSwap module also supports a option called `:confirm_handover` which works togather with the `:handover` option. The `:confirm_handover` option is a boolean that indicates whether the migration handler should wait for the confirmation message from the new process about the handover. If this option is set to `true`, the `:children_migrated_hook` hook will be called once the handover is confirmed, making it possible to react to the handover process.

> #### Retention option {: .info}
> The `retention` option does not mean that the old process will be kept that long alive.
> It is used to limit the time the old processes can stay alive in the handover process
> before they are killed.


### 2. Implement the neccessary callbacks
In order to handover the state our `MyProcess` have to implement the `ProcessHub.Strategy.Migration.Handover` behaviour or define the necessary callbacks.

This can be achieved by using the `ProcessHub.Strategy.Migration.HotSwap` module that provides the necessary callbacks and the default implementation of the `alter_handover_state/1` callback.

```elixir
defmodule MyProcess do
  use GenServer
  use ProcessHub.Strategy.Migration.HotSwap # Provides the necessary callbacks
end
```

Users are free to implement the `alter_handover_state/1` callback in order to modify the state of the process before it is handed over to another node.

```elixir
defmodule MyProcess do
  use GenServer
  use ProcessHub.Strategy.Migration.HotSwap # Provides the necessary callbacks

  def alter_handover_state(old_state) do
    # Do something with the state before returning it
    new_state = Map.put(old_state, :new_key, "new_value")
    
    # Do something else..

    # Return the new state
    new_state
  end
end
```

### 3. That's it!
Now the `ProcessHub` will take care of the rest. When the process is going to be
redirected to another node, the state of the process will be handed over to the new process on
the new node.

## Handover on node leave
The hub takes care of the handover process when a node joins the cluster and processes
migrate to the new node. 
The same can be said when a node leaves the cluster, meaning that the process states on the 
leaving node will be handed over to the remaining nodes but only if the node is shut down **gracefully**.
This leaves the hub with the time to handover the process states to the remaining nodes.
It is advised to scale nodes down one at a time to avoid any data loss(30 second - 10 minute intervals).

## More info can be found in the `Hotswap` module
Check out the [Hotswap](https://hexdocs.pm/process_hub/ProcessHub.Strategy.Migration.HotSwap.html) module for more information.