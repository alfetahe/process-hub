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
A handover happens in three steps: the hub reads the old process's state, starts the new process and gives it that state, then stops the old process. The old process keeps running until the last step, so messages can still reach it after its state was read. Whatever it does with them is not part of the state the new process received.

Nothing changes unless you opt in. With `HotSwap`, set both options:

```elixir
migration_strategy: %ProcessHub.Strategy.Migration.HotSwap{handover: true, forward_messages: true}
```

Then hold messages from the moment the state is read, and pass them on once the hub names the new process:

```elixir
defmodule MyProcess do
  use GenServer
  use ProcessHub.Strategy.Migration.HotSwap

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, {:serving, state}}
  end

  @impl true
  def prepare_handover_state({:serving, state}), do: state
  def alter_handover_state(_current, handover), do: {:serving, handover}

  # Called right after the state was read: stop applying work, hold it instead.
  @impl true
  def handover_state_taken({:serving, state}), do: {:holding, state, []}

  @impl true
  def handle_info({:process_hub, :forward_to, _child_id, pid}, {:holding, state, held}) do
    held |> Enum.reverse() |> Enum.each(&send(pid, &1))
    {:noreply, {:forwarding, state, pid}}
  end

  def handle_info({:work, item}, {:serving, items}), do: {:noreply, {:serving, [item | items]}}
  def handle_info(msg, {:holding, state, held}), do: {:noreply, {:holding, state, [msg | held]}}

  def handle_info(msg, {:forwarding, _state, pid} = s) do
    send(pid, msg)
    {:noreply, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  # The process is stopped right after `forward_to`: pass on what is still in
  # the mailbox. Needs `trap_exit`, set in `init/1`.
  @impl true
  def terminate(_reason, {:forwarding, _state, pid}), do: forward_rest(pid)
  def terminate(_reason, _state), do: :ok

  defp forward_rest(pid) do
    receive do
      msg ->
        send(pid, msg)
        forward_rest(pid)
    after
      0 -> :ok
    end
  end
end
```

`handover_state_taken/1` is optional and returns the process's new state; by default it returns the state unchanged. `{:process_hub, :forward_to, child_id, pid}` is only sent with `handover: true` and `forward_messages: true`, and only to a process whose state was handed over. Calls arrive in `handle_call/3`, not `handle_info/2`; while holding, the simplest is to answer them with an error the caller retries, and the retry reaches the new process.

`ColdSwap` calls `handover_state_taken/1` as well, so a process can stop applying work once its state was read, but it has no forwarding: the new process does not exist yet when the old one stops. Between the two, the child cannot be reached; senders that must not lose work retry until the new process answers.

### When forwarding has ended
With `HotSwap` forwarding, the new process can watch the old one. Put the old pid into the handed-over state and monitor it. The runtime delivers the `:DOWN` message after every message the old process sent before it stopped, so `:DOWN` means nothing more will be forwarded. The old process may also send its own end marker from `terminate/2`; `:DOWN` still covers a crash.

Messages from one process arrive in the order they were sent, but messages from different senders are not ordered against each other. So tag what the old process passes on, for example `send(pid, {:forwarded, msg})` instead of `send(pid, msg)` above. The new process applies forwarded messages as they come, holds its own messages until `:DOWN`, then applies them. Give the wait a time limit.

Some sources reach both processes: for a moment, the old and the new process may each have their own connection to the same external stream. Only an id or sequence number per message lets the new process skip what was already applied; carry the last applied one in the handed-over state. Without ids, the overlap cannot be resolved exactly: a message may be applied twice or missed.

```elixir
defmodule MyProcess do
  use GenServer
  use ProcessHub.Strategy.Migration.HotSwap

  @impl true
  def prepare_handover_state({:serving, items, last_seq}), do: {self(), items, last_seq}

  @impl true
  def alter_handover_state(_current, {old_pid, items, last_seq}) do
    Process.monitor(old_pid)
    Process.send_after(self(), :catch_up_timeout, 5_000)
    {:catching_up, items, last_seq, []}
  end

  @impl true
  def handle_info({:forwarded, msg}, {:catching_up, items, last_seq, held}) do
    {items, last_seq} = apply_work(msg, {items, last_seq})
    {:noreply, {:catching_up, items, last_seq, held}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, {:catching_up, _, _, _} = s),
    do: {:noreply, serve(s)}

  def handle_info(:catch_up_timeout, {:catching_up, _, _, _} = s), do: {:noreply, serve(s)}

  def handle_info(msg, {:catching_up, items, last_seq, held}),
    do: {:noreply, {:catching_up, items, last_seq, [msg | held]}}

  def handle_info({:work, _seq, _item} = msg, {:serving, items, last_seq}) do
    {items, last_seq} = apply_work(msg, {items, last_seq})
    {:noreply, {:serving, items, last_seq}}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp serve({:catching_up, items, last_seq, held}) do
    {items, last_seq} = held |> Enum.reverse() |> Enum.reduce({items, last_seq}, &apply_work/2)
    {:serving, items, last_seq}
  end

  # The sequence number skips a message that was already applied.
  defp apply_work({:work, seq, item}, {items, last_seq}) when seq > last_seq,
    do: {[item | items], seq}

  defp apply_work(_msg, acc), do: acc
end
```

## More info can be found in the `Hotswap` module
Check out the [Hotswap](https://hexdocs.pm/process_hub/ProcessHub.Strategy.Migration.HotSwap.html) module for more information.