# Manual distribution

## Introduction
By default `ProcessHub` uses the `ProcessHub.Strategy.Distribution.ConsistentHashing` strategy to distribute processes.
This is automatic and the `ProcessHub` will decide which node to start the process on.
This strategy is useful for most use cases, but sometimes you may want to distribute processes manually. This guide will show you how to do that.

By manually distributing processes, you can control which processes are started on which nodes. 
This can be useful when you want to distribute processes based on specific criteria, such as the node's hardware capabilities or the process's workload.

Let's dive in a see some examples.

## Example GenServer
As always our processes should have some template to follow. Here is a simple `GenServer` process that we will use in our examples:

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

## The configuration
First, let's configure the `ProcessHub` to use the `ProcessHub.Strategy.Distribution.Guided` strategy.

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
      # We have to swap the default distribution strategy with the guided one.
      distribution_strategy: %ProcessHub.Strategy.Distribution.Guided{}
    }}
  end
end
```

## Start 2 nodes
Now let's start 2 nodes and connect them to each other.

```bash
iex --name node1@127.0.0.1 --cookie mycookie -S mix
```

```bash
iex --name node2@127.0.0.1 --cookie mycookie -S mix
```

From node 1, connect to node 2(or vice versa):
```elixir
Node.connect(:"node2@127.0.0.1")
```


## Start distributed processes.
Now let's start a process on node 1 and guide it to node 2.

```elixir
iex> node1_child = %{id: :node1_child, start: {MyProcess, :start_link, [nil]}}
iex> node2_child = %{id: :node2_child, start: {MyProcess, :start_link, [nil]}}
iex> ProcessHub.start_children(:my_hub, [node1_child, node2_child], [
...>    child_mapping: %{
...>        node1_child: [:"node1@127.0.0.1"],
...>        node2_child: [:"node2@127.0.0.1"],
...>    }
...> ])
```

In the example above, we started 2 processes, `node1_child` and `node2_child`. We also specified that `node1_child` should be started on node 1 and `node2_child` should be started on node 2.

We do this by adding the `child_mapping` option to the `ProcessHub.start_children/3` function. The `child_mapping` option is a map that specifies which node to start the process on.
Each key in the map is the `id` of the process and the value is a list of nodes to start the process on.

> #### Why use lists to specify the node?
> The reason we use lists for the `child_mapping` is that we can specify multiple nodes for a 
> process if we want to replicate the process on multiple nodes. 
>
>This requires the `ProcessHub.Strategy.Redundancy.Replication` strategy to be used. Which we will cover in another guide.
> For example: `node1_child: [:"node1@127.0.0.1", :"node2@127.0.0.1"]`


## Checking the registered processes
Now let's check the registered processes on each node.

```elixir
iex> ProcessHub.process_list(:my_hub, :global)
[
  node1_child: ["node1@127.0.0.1": #PID<0.280.0>],
  node2_child: ["node2@127.0.0.1": #PID<22474.276.0>]
]
```

We can see that the `node1_child` process is registered on node 1 and the `node2_child` process is registered on node 2.


> #### The `child_mapping` is mandatory {: .error}
> If we decide to use the `ProcessHub.Strategy.Distribution.Guided` strategy, we have to specify the `child_mapping` option when starting the processes. Otherwise `{:error, :missing_child_mapping}` will be returned when starting the processes.