# Creating custom strategy

It's time to extend the functionality of the `ProcessHub` and we will do this
by creating a custom strategy distribution strategy.

## Implementation

Our custom distribution strategy will be very simple and probably not very
useful in practice, but it will serve as a good example of how to create one.

This distribution strategy will distribute processes by comparing the node names. We will also take advance
of using hook system to further customize the behavior of the system.

Let's start by creating a new file called `compare.ex`. We can place the file anywhere
in the project as long as it is picked up by the compiler.

It is a good practice to add some custom name spacing to the module to avoid conflicts
with other modules. We will use `CustomStrategy` as the namespace.
```elixir
defmodule CustomStrategy.Compare do
end
```

Our custom distribution strategy should define a struct which can contain any 
number of custom options. In our example, we will define a single option called
`direction` which will determine if the selected node is either the first or the last
node in the list of nodes.

We will also create our implementation the `ProcessHub.Strategy.Distribution.Base` protocol.
```elixir
defmodule CustomStrategy.Compare do

    alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy

    # We can define custom options.
    defstruct [
        direction: :asc     
    ]

    defimpl DistributionStrategy, for: CustomStrategy.Compare do
    end
end
```

The `ProcessHub.Strategy.Distribution.Base` protocol defines some functions that we need to implement. The first function is the `init/2` function which is called very early when
the coordinator is started. This can be very good place to register any custom
hook handlers that we need to use. We will register a handler that will print the name of
the node that is joining the hub.

```elixir
...
defimpl DistributionStrategy, for: CustomStrategy.Compare do
    alias ProcessHub.Service.HookManager
    alias ProcessHub.Constant.Hook

    @impl true
    def init(_struct, %ProcessHub.Hub{} = hub) do
      handler = %HookManager{
        id: :some_id_here,
        m: CustomStrategy.Compare,
        f: :handle_node_join,
        a: [hub, :_]
      }

      HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_join(), handler)
    end
end
...
```

Let's also define the handler function!

```elixir
defmodule CustomStrategy.Compare do
...
    def handle_node_join(hub, node) do
        IO.puts("Node #{node} is joining the hub #{hub.hub_id}")
    end
end
...
```

At this point we only have 2 more functions to implement. Let's continue by 
overriding the `children_init/4` function which does nothing but return `:ok`.
If we return anything else other than `:ok`, the startup will fail for this
particular function.

```elixir
...
@impl true
def children_init(_struct, _hub, _child_specs, _opts), do: :ok
...
```

We now have the last function to implement which is the `belongs_to/4` function. This function will determine the node that the process should be distributed to. In our case, we will select a node based on it's name. 

The very same function will also be used when processes are redistributed.

We also return a list of nodes although we only select one, the reason for this is that the function can return multiple nodes in case the process should be replicated.
For the sake of simplicity, we will ignore the replication factor in this example.

```elixir
...
@impl true
def belongs_to(struct, %ProcessHub.Hub{} = hub, _child_id, _replication_factor) do
    hub_nodes = ProcessHub.nodes(hub, [:include_local])

    selected_node = case struct.direction do
        :asc -> Enum.sort(hub_nodes) |> Enum.at(0)
        :desc -> Enum.sort(hub_nodes) |> Enum.reverse() |> Enum.at(0)
    end

    [selected_node] # Ignore the replication factor and just return one node
end
...
```

This is it!

## Final implementation

Our final implementation of the `CustomStrategy.Compare` module should look like this:

```elixir
defmodule CustomStrategy.Compare do
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy

  # We can define custom options.
  defstruct [
    direction: :asc
  ]

  def handle_node_join(%ProcessHub.Hub{} = hub, node) do
      IO.puts("Node #{node} is joining the hub #{hub.hub_id}")
  end

  defimpl DistributionStrategy, for: CustomStrategy.Compare do
    alias ProcessHub.Service.HookManager
    alias ProcessHub.Constant.Hook

    @impl true
    def init(_struct, %ProcessHub.Hub{} = hub) do
      handler = %HookManager{
        id: :some_id_here,
        m: CustomStrategy.Compare,
        f: :handle_node_join,
        a: [hub, :_]
      }

      HookManager.register_handler(hub.storage.hook, Hook.pre_cluster_join(), handler)
    end

    @impl true
    def children_init(_struct, _hub, _child_specs, _opts), do: :ok

    @impl true
    def belongs_to(struct, %ProcessHub.Hub{} = hub, _child_id, _replication_factor) do
        hub_nodes = ProcessHub.nodes(hub, [:include_local])

        selected_node = case struct.direction do
            :asc -> Enum.sort(hub_nodes) |> Enum.at(0)
            :desc -> Enum.sort(hub_nodes) |> Enum.reverse() |> Enum.at(0)
        end

        [selected_node] # Ignore the replication factor and just return one node
    end
  end
end
```

## Switching to the custom strategy

Replace the default distribution strategy with our custom strategy in the `ProcessHub` configuration.
```elixir
defmodule MyAp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [process_hub()]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp process_hub() do
    {ProcessHub, %ProcessHub{
      hub_id: :my_hub,
      distribution_strategy: %CustomStrategy.Compare{
        direction: :desc
      }
    }}
  end
end

```

## Test drive

Let's start two nodes on separate terminals.

```bash
iex --name node1@127.0.0.1 --cookie mycookie -S mix
```

```bash
iex --name node2@127.0.0.1 --cookie mycookie -S mix
```

Connect the nodes by running the following command on the `node1` terminal.
```elixir
iex> Node.connect(:"node2@127.0.0.1")
true
```

Time to see the magic happen!
```elixir
iex> ProcessHub.start_children(:my_hub, [
...>    %{id: "process1", start: {MyProcess, :start_link, [nil]}},
...>    %{id: "process2", start: {MyProcess, :start_link, [nil]}},
...>    %{id: "process3", start: {MyProcess, :start_link, [nil]}},
...>    %{id: "process4", start: {MyProcess, :start_link, [nil]}},
...>    %{id: "process5", start: {MyProcess, :start_link, [nil]}}
...> ])
{:ok, :start_initiated}
iex> ProcessHub.process_list(:my_hub, :global)
[
  process1: ["node2@127.0.0.1": #PID<23066.269.0>],
  process2: ["node2@127.0.0.1": #PID<23066.270.0>],
  process3: ["node2@127.0.0.1": #PID<23066.271.0>],
  process4: ["node2@127.0.0.1": #PID<23066.272.0>],
  process5: ["node2@127.0.0.1": #PID<23066.273.0>]
]
```
We can confirm that all processes are started on the second node if we
pass the `:desc` option to the struct.

