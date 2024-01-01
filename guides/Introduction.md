# Getting started

In this guide we will go through the basic usage of `ProcessHub` and how to integrate 
it in your application.

To get more familiar with the public API of `ProcessHub`, please refer to the `ProcessHub` module.

## Installation

In order to use `ProcessHub` in your application, you need to add it as a dependency.
Once you have added it as a dependency, you need to start the `ProcessHub` master supervisor.
It is highly recommended to start the `ProcessHub` supervisor under your application 
supervision tree.

1. Add `process_hub` to your list of dependencies in `mix.exs`:
    ```elixir
    def deps do
        [
            {:process_hub, "~> 0.2.0-alpha"}
        ]
    end
    ```

2. Pull the dependency:
    ```bash
    mix deps.get
    ```

3. Start the `ProcessHub` supervisor under your application supervision tree:
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

> #### Hub ID {: .neutral}
>
> Each node in the cluster that starts a `ProcessHub` instance and shares the same `:hub_id` will 
> form a hub cluster.
>
> It is possible to start multiple hubs under the same supervision tree with
> different configuration options, in this case, each hub must have a unique `:hub_id`.

## Example usage
The following example shows how to start 2 elixir nodes, connect them and start processes
under the `ProcessHub` cluster. This demonstrates how the processes are distributed within
the cluster.

**Note:** The examples below assume that the `ProcessHub` is already started under the
supervision tree. If not please refer to the [Installation](#installation) section.

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
  "node1@127.0.0.1": [
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