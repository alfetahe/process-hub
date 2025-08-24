# ProcessRegistry

The `ProcessRegistry` is a global registry that keeps track of all the processes in the system. 
It is used to look up a process by its name, and to register a process with a name.

It's recommended to interact with `ProcessRegistry` through the main `ProcessHub` API module.

By default `ProcessRegistry` is using pubs/subs mechanism to notify subscribers about changes in the registry. This implementation can be replaced with `ProcessHub.Strategy.Synchronization.Gossip` or
custom implementation.

ProcessRegistry can also be used to store metadata about the processes, such as tags or other information. 
This can be useful to group processes, query them by tags or distribute data among them and trigger any custom logic.
The metadata is synchronized across the cluster, so all nodes will have the same information about the processes.

We will skip the boiler plate code for starting the child processes and focus on the registry itself.

## Querying the whole registry
We will start of by querying the whole registry with `ProcessHub.process_list/2` function.

This function allows us to query the whole registry or a specific hub and specify if we want to include remote processes or not.

If we choose to exclude remote processes, the node names wont be included in the returned list.
We can switch between `:global` and `:local` mode by passing the second argument to the function.

The `ProcessHub.process_list/2`function is the most efficient way to query the whole registry because
the data is coming from the local registry and no network calls are made.


```elixir
iex> ProcessHub.process_list(:my_hub, :global)
[
  my_process_1: [two@anuar: #PID<23772.233.0>],
  my_process_2: [one@anuar: #PID<0.250.0>],
  my_process_3: [one@anuar: #PID<0.253.0>],
  my_process_4: [one@anuar: #PID<0.256.0>],
  my_process_5: [one@anuar: #PID<0.259.0>],
  my_process_6: [one@anuar: #PID<0.262.0>],
  my_process_7: [one@anuar: #PID<0.265.0>],
  my_process_8: [two@anuar: #PID<23772.254.0>],
  my_process_9: [one@anuar: #PID<0.271.0>],
  my_process_10: [one@anuar: #PID<0.274.0>]
]

iex> ProcessHub.process_list(:my_hub, :local)
[
  my_process_2: #PID<0.250.0>,
  my_process_3: #PID<0.253.0>,
  my_process_4: #PID<0.256.0>,
  my_process_5: #PID<0.259.0>,
  my_process_6: #PID<0.262.0>,
  my_process_7: #PID<0.265.0>,
  my_process_9: #PID<0.271.0>,
  my_process_10: #PID<0.274.0>
]
```


Another similar option is `ProcessHub.registry_dump/1` which dumps the whole registry into a map
including metadata stored in the registry.
```elixir
iex> ProcessHub.registry_dump(:my_hub)
%{
  my_process_1: {%{id: :my_process_1, start: {MyProcess, :start_link, []}},
   [two@anuar: #PID<23772.233.0>], %{tag: "Some tag"}},
  my_process_2: {%{id: :my_process_2, start: {MyProcess, :start_link, []}},
   [one@anuar: #PID<0.250.0>], %{custom_data: "Some data"}},
  my_process_3: {%{id: :my_process_3, start: {MyProcess, :start_link, []}},
   [one@anuar: #PID<0.253.0>], %{}},
  my_process_4: {%{id: :my_process_4, start: {MyProcess, :start_link, []}},
   [one@anuar: #PID<0.256.0>], %{}},
  my_process_5: {%{id: :my_process_5, start: {MyProcess, :start_link, []}},
   [one@anuar: #PID<0.259.0>], %{}},
  my_process_6: {%{id: :my_process_6, start: {MyProcess, :start_link, []}},
   [one@anuar: #PID<0.262.0>], %{}},
  my_process_7: {%{id: :my_process_7, start: {MyProcess, :start_link, []}},
   [one@anuar: #PID<0.265.0>], %{}},
  my_process_8: {%{id: :my_process_8, start: {MyProcess, :start_link, []}},
   [two@anuar: #PID<23772.254.0>], %{}},
  my_process_9: {%{id: :my_process_9, start: {MyProcess, :start_link, []}},
   [one@anuar: #PID<0.271.0>], %{}},
  my_process_10: {%{id: :my_process_10, start: {MyProcess, :start_link, []}},
   [one@anuar: #PID<0.274.0>], %{}}
}
```


There's also a third option `ProcessHub.which_children/2` but is highly discouraged to use and may 
be deprecated in the future.

This function does network calls to all nodes in the cluster to get the list of processes and
also may lead to memory and performance issues when used with large nuber of processes.

It's using the `Supervisor.which_children/1` function under the hood which has stated in the 
documentation: **Note that calling this function when supervising a large number of children
  under low memory conditions can cause an out of memory exception.**

Here is an example of how to use `ProcessHub.which_children/2` function:

```elixir
iex> ProcessHub.which_children(:my_hub, [:global])
[
  one@anuar: [
    {:my_process_10, #PID<0.274.0>, :worker, [MyProcess]},
    {:my_process_9, #PID<0.271.0>, :worker, [MyProcess]},
    {:my_process_7, #PID<0.265.0>, :worker, [MyProcess]},
    {:my_process_6, #PID<0.262.0>, :worker, [MyProcess]},
    {:my_process_5, #PID<0.259.0>, :worker, [MyProcess]},
    {:my_process_4, #PID<0.256.0>, :worker, [MyProcess]},
    {:my_process_3, #PID<0.253.0>, :worker, [MyProcess]},
    {:my_process_2, #PID<0.250.0>, :worker, [MyProcess]}
  ],
  two@anuar: [
    {:my_process_8, #PID<23772.254.0>, :worker, [MyProcess]},
    {:my_process_1, #PID<23772.233.0>, :worker, [MyProcess]}
  ]
]

iex> ProcessHub.which_children(:my_hub, [:local])
{:one@anuar,
 [
   {:my_process_10, #PID<0.274.0>, :worker, [MyProcess]},
   {:my_process_9, #PID<0.271.0>, :worker, [MyProcess]},
   {:my_process_7, #PID<0.265.0>, :worker, [MyProcess]},
   {:my_process_6, #PID<0.262.0>, :worker, [MyProcess]},
   {:my_process_5, #PID<0.259.0>, :worker, [MyProcess]},
   {:my_process_4, #PID<0.256.0>, :worker, [MyProcess]},
   {:my_process_3, #PID<0.253.0>, :worker, [MyProcess]},
   {:my_process_2, #PID<0.250.0>, :worker, [MyProcess]}
 ]}
```

## Querying a specific child

To quickly get the PID of the running process by it's `child_id` we can use the
`ProcessHub.get_pid/2` function which returns the process identifier.

```elixir
iex> ProcessHub.get_pid(:my_hub, :my_process_10)
#PID<0.228.0>
```

Now when utilizing replication strategies we should default to another function `ProcessHub.get_pids/2`
which returns a list of PIDs for the given `child_id`.

```elixir
iex> ProcessHub.get_pids(:my_hub, :my_process_10)
[#PID<0.228.0>]
```

We may also query the whole child info by using the `ProcessHub.which_children/2` function.
This function also gives us the `child_spec`.

```elixir
iex> ProcessHub.child_lookup(:my_hub, :my_process_10)
{
    %{id: :my_process_10, start: {MyProcess, :start_link, []}},
    [one@anuar: #PID<0.228.0>]
}
 ```

## Process metadata
We can store metadata in the registry by starting the process with `:metadata` option.

```elixir
# First we need to start the process with metadata
iex> ProcessHub.start_child(
  :my_hub, 
  %{id: :my_process_1, start: {MyProcess, :start_link, []}}, 
  [metadata: %{some_info: "my data"}, awaitable: true]
) |> ProcessHub.Future.await()
{:ok, #PID<0.228.0>} # TODO: update

# Now we can query the process with metadata
iex> ProcessHub.child_lookup(:my_hub, :my_process_1, [with_metadata: true])
{
  %{id: :my_process_1, start: {MyProcess, :start_link, []}},
  [one@anuar: #PID<0.228.0>],
  %{some_info: "my data"}
}
```

We can also get all the metadata stored for all the processes in the registry by using
`ProcessHub.registry_dump/1` function.

```elixir
iex> ProcessHub.registry_dump(:my_hub)
%{
  my_process_1: {%{id: :my_process_1, start: {MyProcess, :start_link, []}},
   [one@anuar: #PID<0.228.0>], %{some_info: "my data"}},
  my_process_2: {%{id: :my_process_2, start: {MyProcess, :start_link, []}},
   [one@anuar: #PID<0.250.0>], %{}},
  my_process_3: {%{id: :my_process_3, start: {MyProcess, :start_link, []}},
   [one@anuar: #PID<0.253.0>], %{}}
}
```

`ProcessHub` is also internally using `:metadata` to tag processes which is then used
to query the processes by tags.
```elixir
iex> ProcessHub.tag_query(:my_hub, "MY_TAG")
[
  my_process_1: {%{id: :my_process_1, start: {MyProcess, :start_link, []}},
   [one@anuar: #PID<0.228.0>]},
  my_process_2: {%{id: :my_process_2, start: {MyProcess, :start_link, []}},
   [one@anuar: #PID<0.250.0>]}
]
```