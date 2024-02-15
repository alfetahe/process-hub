# Replicating processes

In a distributed system, it can be important to replicate processes within a cluster of nodes. This can lead to better resilience and reliability of the system.
When one node unexpectedly fails, the replicated processes on other nodes can take over the work of the failed node immediately.

In this guide, we will show a simple example of how to replicate processes and prioritize them.

## Prerequisites
As always we should have some process template to follow. You can re use the `MyProcess` GenServer from the [Manual Distribution](ManualDistribution.md#example-genserver) guide.

## The configuration
First, let's configure the `ProcessHub` to use the `ProcessHub.Strategy.Redundancy.Replication` strategy.

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
      redundancy_strategy: %ProcessHub.Strategy.Redundancy.Replication{    
        replication_factor: 2,
        replication_model: :active_passive,
        redundancy_signal: :all
      },
    }}
  end
end
```

Let's explain the used options:
- `replication_factor`: The number of replicas that will be created for each process. Meaning if the value is 2, then the process will be replicated on 2 nodes.
- `replication_model`: This is optional and can be either `:active_passive` or `:active_active`. The `:active_passive` model means that only one of the replicas will be marked as active and the others will be passive. We will get into more details about this later.
- `redundancy_signal`: This is optional and can be used to toggle on/off the message sent
to the replicas to notify them about their current state (`:passive` or `:active`). This all will be explained in the next sections.


## Start 2 nodes
Now let's start two nodes and connect them to each other. 
You can refer to the [Manual Distribution](ManualDistribution.md#start-2-nodes) guide for an example.

## Start child
Next let's start a process on one node and then see how it is replicated on the other node.

We will be using the `async_wait` just for demonstration purposes and see the results printed in the console.

```elixir
iex> child_spec = %{id: :child1, start: {MyProcess, :start_link, [nil]}}
iex> ProcessHub.start_children(:my_hub, [child_spec], [async_wait: true]) |> ProcessHub.await()
{:ok,
 [
   child1: [
     "node1@127.0.0.1": #PID<0.264.0>,
     "node2@127.0.0.1": #PID<22914.996.0>
   ]
 ]}
***17:08:08.277 [error] MyProcess #PID<0.264.0> received unexpected message in handle_info/2: {:process_hub, :redundancy_signal, :passive}***
```

If we examine the result, we can see that the process `child1` was started on both nodes, meaning it was replicated.

**But what's up with the error message?**

Well, the error message is expected. It is a signal sent to the process to notify it that it is either in passive or active mode. This is part of the `redundancy_signal` option we set in the `ProcessHub` configuration.

We could have used the `redundancy_signal: :none` option to disable the signal, but we wanted to show you how it works.

> #### Redundancy Signal {: .warning}
> The `redundancy_signal` option is used to toggle on/off the message sent to the replicas to notify them about their current state (`:passive` or `:active`). 
> This message needs to be handled by the process.

Here's an example how we handle the signal in the `MyProcess`. In the following example, we
save the signal in the state and handle incoming messages based on the state.

```elixir
# The necceassary callbacks we have to implement.
def handle_info({:process_hub, :redundancy_signal, mode}, state) do
    # Save the mode in the state for later use.
    {:noreply, %{mode: mode}}
end

def handle_info({:handle_request, _request}, %{mode: :passive} = state) do
    # Ignore and don't do anything because we're the passive process.
    {:noreply, state}
end

def handle_info({:handle_request, request}, %{mode: :aactive} = state) do
    # Handle the request because we're the active process.
    handle_request(request)
    {:noreply, state}
end
```

## Conclusion
The `ProcessHub.Strategy.Redundancy.Replication` can be used not only for replicating processes but also to manipulate the behavior of the replicas. This can be done by using the `:redundancy_signal` with `:replication_model` options.

`ProcessHub` defines currently two redundancy strategies, You can check these modules for custom configuration options:
- `ProcessHub.Strategy.Redundancy.Replication`
- `ProcessHub.Strategy.Redundancy.Singularity`
