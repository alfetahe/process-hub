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
        handover: true,
        state_ttl: 30_000,
        state_query_timeout: 5_000
      },
    }}
  end
end
```

Pay attention to the `handover`, `state_ttl` and `state_query_timeout` options. The `handover` option is a boolean that indicates whether the process state should be handed over to another node when the process is going to be stopped. The `state_ttl` option is the max time in milliseconds that a queried state is kept before it is discarded, and `state_query_timeout` is the max time to wait for the local process to reply with its state.

Once the state has been delivered to the new process, the `handover_delivered` hook is
dispatched, making it possible to react to the handover.

> #### State TTL {: .info}
> The `state_ttl` option does not keep the old process alive. It only limits how long
> the handed-over state is retained before it is dropped.

### 2. Implement the neccessary callbacks
In order to handover the state our `MyProcess` have to implement the `ProcessHub.Strategy.Migration.HandoverBehaviour` behaviour or define the necessary callbacks.

This can be achieved by using the `ProcessHub.Strategy.Migration.HotSwap` module that provides the necessary callbacks and the default implementation of the `prepare_handover_state/1` and `alter_handover_state/2` callbacks

```elixir
defmodule MyProcess do
  use GenServer
  use ProcessHub.Strategy.Migration.HotSwap # Provides the necessary callbacks
end
```

Users are free to implement the `alter_handover_state/2` callback in order to modify the state of the process before it is handed over to another node.

```elixir
defmodule MyProcess do
  use GenServer
  use ProcessHub.Strategy.Migration.HotSwap # Provides the necessary callbacks

  # This is called on the process that is going to pass the state to another
  # newly spawned process. The returned value of this function will be passed to the
  # `alter_handover_state/2` function on the process that is going to accept the new state.
  @impl true
  def prepare_handover_state(state) do
    state
  end

  # This is called on the process that is going to accept the new handover state.
  # The process must return the new state that will be used by the process.
  @impl true
  def alter_handover_state(current_state, handover_state) do
    new_value = Map.get(handover_state, :some_key)

    # Do something with the state before returning it
    new_state = Map.put(current_state, :some_key, new_value)

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

## Messages that arrive during a handover
A handover reads the old process's state, gives it to the new process and stops the old one. With `HotSwap` the old process keeps running until the new one has its state; with `ColdSwap` it runs until it is stopped. Messages can still reach it after its state was read, and whatever it does with them is not part of the state the new process received.

To keep those messages, turn on `forward_messages` in the migration strategy. Your process code stays the same:

```elixir
migration_strategy: %ProcessHub.Strategy.Migration.HotSwap{handover: true, forward_messages: true}
# or
migration_strategy: %ProcessHub.Strategy.Migration.ColdSwap{handover: true, forward_messages: true}
```

From the moment its state is read, the old process stops handling messages and keeps them instead.

- With `HotSwap`, it passes them on to the new process once that one has its state. It then passes on whatever else arrives until it is stopped, including what is still in its mailbox.
- With `ColdSwap`, it keeps them until it is stopped. They are stored with its state, and the new process gets them right after the state.

The new process handles each passed-on message as if it had been sent to it: `handle_cast/2`, `handle_info/2`, or `handle_call/3` with the answer going to the original caller.

Things to know:

- **Only processes that `use` the `HotSwap` or `ColdSwap` macro** take part, as with state handover itself.
- **If no new process takes over in time**, the old one goes back to work after `state_ttl` and handles the kept messages itself, in order.
- **Order:** passed-on messages keep their order among themselves. They are handled after the messages already waiting in the new process, and they are not ordered against messages sent to the new process directly.
- **Calls:** the old process stops right after passing on its last messages, and a caller waiting on it may see that exit before the new process answers, even though the call is still handled. With `ColdSwap` the gap is longer, so callers usually time out. Make such calls safe to retry.
- **Not passed on:** the old process's own `:DOWN` and `:EXIT` notices, which are about its monitors and links, not the new process's.
- **A message that reaches the old process as it exits is lost**, as it is with any process that stops. Senders that keep its pid should look it up again once it is gone.
- **Node shutdown:** messages are passed on when a child moves while the hub keeps running. When a node shuts down and hands its states over (see above), nothing is passed on.

### Messages that reach both processes
For a moment, the old and the new process may each receive the same thing: two connections to one external stream, or a sender that retried a call. Only an id or sequence number per message lets the new process skip what was already applied; carry the last applied one in the handed-over state. Without ids, the overlap cannot be resolved exactly: a message may be applied twice or missed.

```elixir
defmodule MyProcess do
  use GenServer
  use ProcessHub.Strategy.Migration.HotSwap

  @impl true
  def handle_info({:work, seq, item}, {items, last_seq}) when seq > last_seq,
    do: {:noreply, {[item | items], seq}}

  # Already applied, by this process or before the handover.
  def handle_info({:work, _seq, _item}, state), do: {:noreply, state}
end
```

## More info can be found in the `Hotswap` module
Check out the [Hotswap](https://hexdocs.pm/process_hub/ProcessHub.Strategy.Migration.HotSwap.html) module for more information.