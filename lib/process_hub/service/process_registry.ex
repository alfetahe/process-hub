defmodule ProcessHub.Service.ProcessRegistry do
  @moduledoc """
  The process registry service provides API functions for managing the process registry.
  """

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Storage

  use GenServer

  @default_timeout 10_000

  @type registry() :: %{
          ProcessHub.child_id() => {
            ProcessHub.child_spec(),
            [{node(), pid()}]
          }
        }

  @type registry_dump() :: %{
          ProcessHub.child_id() => {
            ProcessHub.child_spec(),
            [{node(), pid()}],
            metadata()
          }
        }

  @type metadata() :: %{
          tag: String.t()
        }

  def start_link({hub_id, via_tuple}) do
    GenServer.start_link(__MODULE__, hub_id, name: via_tuple)
  end

  @impl GenServer
  def init(hub_id) do
    # The registry table is opened by the Coordinator (via the
    # configured Storage.Behaviour backend). This GenServer exists to
    # serialise mutations through `handle_call/3`; it does not own the
    # underlying storage handle.
    {:ok, hub_id}
  end

  @impl GenServer
  def handle_call({:insert, hub_id, child_spec, child_nodes, opts}, _from, state) do
    {:reply, handle_insert(hub_id, child_spec, child_nodes, opts), state}
  end

  @impl GenServer
  def handle_call({:delete, hub_id, child_id, opts}, _from, state) do
    {:reply, handle_delete(hub_id, child_id, opts), state}
  end

  @impl GenServer
  def handle_call({:bulk_insert, hub_id, children, opts}, _from, state) do
    {:reply, handle_bulk_insert(hub_id, children, opts), state}
  end

  @impl GenServer
  def handle_call({:bulk_delete, hub_id, children, opts}, _from, state) do
    {:reply, handle_bulk_delete(hub_id, children, opts), state}
  end

  @impl GenServer
  def handle_call({:update, hub_id, child_id, update_fn}, _from, state) do
    {:reply, handle_update(hub_id, child_id, update_fn), state}
  end

  @impl GenServer
  def handle_call({:clear_all, hub_id}, _from, state) do
    {:reply, handle_clear_all(hub_id), state}
  end

  @doc "Returns information about all registered processes. Will be deprecated in the future."
  @spec registry(ProcessHub.hub_id()) :: registry()
  def registry(hub_id) do
    Storage.foldl(hub_id, %{}, fn
      {_child_id, {_child_spec, [], _metadata}}, acc ->
        acc

      {_child_id, {_child_spec, [], _metadata}, _ttl}, acc ->
        acc

      {child_id, {child_spec, nodes, _metadata}}, acc ->
        Map.put(acc, child_id, {child_spec, nodes})

      {child_id, {child_spec, nodes, _metadata}, _ttl}, acc ->
        Map.put(acc, child_id, {child_spec, nodes})
    end)
  end

  @doc """
  Dumps the whole registry.

  Returns all information about all registered processes including metadata.
  Entries with empty node lists are excluded.
  """
  @spec dump(ProcessHub.hub_id()) :: registry_dump()
  def dump(hub_id) do
    hub_id
    |> Storage.export_all()
    |> Enum.reduce(%{}, fn
      {_key, {_spec, [], _meta}}, acc -> acc
      {_key, {_spec, [], _meta}, _ttl}, acc -> acc
      {key, values}, acc -> Map.put(acc, key, values)
      {key, values, _ttl}, acc -> Map.put(acc, key, values)
    end)
  end

  @doc """
  Dumps the whole registry including entries with empty node lists.

  Unlike `dump/1`, this includes all entries regardless of their node list,
  such as pending forwarding entries and TTL tombstone entries.
  """
  @spec dump_all(ProcessHub.hub_id()) :: registry_dump()
  def dump_all(hub_id) do
    hub_id
    |> Storage.export_all()
    |> Enum.map(fn
      {key, values} -> {key, values}
      {key, values, _ttl} -> {key, values}
    end)
    |> Map.new()
  end

  @spec process_list(atom(), :global | :local) :: [
          {ProcessHub.child_id(), [{node(), pid()}] | pid()}
        ]
  def process_list(hub_id, :global) do
    Storage.foldl(hub_id, [], fn
      {child_id, {_child_spec, nodes, _metadata}}, acc when nodes != [] ->
        [{child_id, nodes} | acc]

      {child_id, {_child_spec, nodes, _metadata}, _ttl}, acc when nodes != [] ->
        [{child_id, nodes} | acc]

      _, acc ->
        acc
    end)
  end

  def process_list(hub_id, :local) do
    local_node = node()

    process_list(hub_id, :global)
    |> Enum.map(fn {child_id, nodes} ->
      {child_id, Keyword.get(nodes, local_node)}
    end)
    |> Enum.filter(fn {_, pid} -> pid end)
  end

  @spec contains_children(ProcessHub.hub_id(), [ProcessHub.child_id()]) :: [ProcessHub.child_id()]
  @doc "Returns a list of child_ids that match the given `child_ids` variable."
  def contains_children(hub_id, child_ids) do
    child_id_set = MapSet.new(child_ids)

    Storage.foldl(hub_id, [], fn
      {_child_id, {_spec, [], _meta}}, acc ->
        acc

      {_child_id, {_spec, [], _meta}, _ttl}, acc ->
        acc

      {child_id, _}, acc ->
        if MapSet.member?(child_id_set, child_id), do: [child_id | acc], else: acc

      {child_id, _, _ttl}, acc ->
        if MapSet.member?(child_id_set, child_id), do: [child_id | acc], else: acc
    end)
    |> Enum.reverse()
  end

  @doc "Returns all children that match the given tag."
  @spec match_tag(ProcessHub.hub_id(), String.t()) :: [
          {ProcessHub.child_id(), [{node(), pid()}]}
        ]
  def match_tag(hub_id, tag) do
    match_expr = {:"$1", {:_, :"$3", %{tag: tag}}}

    Storage.match(hub_id, match_expr)
  end

  @doc "Deletes all objects from the process registry."
  @spec clear_all(ProcessHub.hub_id()) :: boolean()
  def clear_all(hub_id) do
    GenServer.call(via(hub_id), {:clear_all, hub_id})
  end

  @doc """
  Removes `restarted_node` from every binding's `node_pids` list.

  Used by the fast-restart purge signal (`{:cluster_join, {:restarted,
  node}}`): when a peer restarts within `:net_ticktime`, other peers
  may still be holding bindings whose pid lives on the restarted node.
  This helper rewrites those rows so the dead pid is dropped before
  `init_sync` runs against the rejoined peer.

  A binding whose `node_pids` becomes empty is removed entirely; the
  restarted peer will re-register the cspec via its own replay or via
  `init_sync`.
  """
  @spec purge_node_bindings(ProcessHub.hub_id(), node()) :: :ok
  def purge_node_bindings(hub_id, restarted_node) do
    Storage.foldl(hub_id, [], fn entry, acc ->
      [entry | acc]
    end)
    |> Enum.each(fn entry ->
      case purge_entry(entry, restarted_node) do
        :unchanged ->
          :ok

        {:update, child_id, {child_spec, new_nodes, metadata}} ->
          Storage.insert(hub_id, child_id, {child_spec, new_nodes, metadata})

        {:delete, child_id} ->
          Storage.remove(hub_id, child_id)
      end
    end)

    :ok
  end

  defp purge_entry({child_id, {child_spec, node_pids, metadata}}, restarted_node) do
    new_pids = Enum.reject(node_pids, fn {n, _} -> n == restarted_node end)

    cond do
      new_pids == node_pids -> :unchanged
      new_pids == [] -> {:delete, child_id}
      true -> {:update, child_id, {child_spec, new_pids, metadata}}
    end
  end

  defp purge_entry({child_id, {child_spec, node_pids, metadata}, _ttl}, restarted_node) do
    purge_entry({child_id, {child_spec, node_pids, metadata}}, restarted_node)
  end

  defp purge_entry(_other, _node), do: :unchanged

  @doc "Returns information on all processes that are running on the local node."
  @spec local_data(ProcessHub.hub_id()) :: [
          {ProcessHub.child_id(), {ProcessHub.child_spec(), [{node(), pid()}]}}
        ]
  def local_data(hub_id) do
    local_node = node()

    Storage.foldl(hub_id, [], fn
      {child_id, {_, nodes, _} = value}, acc ->
        if Keyword.has_key?(nodes, local_node), do: [{child_id, value} | acc], else: acc

      {child_id, {_, nodes, _} = value, _ttl}, acc ->
        if Keyword.has_key?(nodes, local_node), do: [{child_id, value} | acc], else: acc
    end)
  end

  @doc "Returns a list of child specs registered under the local node."
  @spec local_child_specs(ProcessHub.hub_id()) :: [ProcessHub.child_spec()]
  def local_child_specs(hub_id) do
    local_data(hub_id)
    |> Enum.map(fn
      {_, {child_spec, _, _}} -> child_spec
    end)
  end

  @doc "Returns a list of pids for the given child_id."
  @spec get_pids(ProcessHub.hub_id(), ProcessHub.child_id()) :: [pid()]
  def get_pids(hub_id, child_id) do
    case lookup(hub_id, child_id) do
      nil -> []
      {_, node_pids} -> Enum.map(node_pids, fn {_, pid} -> pid end)
    end
  end

  @doc "Returns the first pid for the given child_id."
  @spec get_pid(ProcessHub.hub_id(), ProcessHub.child_id()) :: pid() | nil
  def get_pid(hub_id, child_id) do
    get_pids(hub_id, child_id) |> List.first()
  end

  @doc "Returns the local pid for the given child_id, or nil if not found on local node."
  @spec local_pid(ProcessHub.hub_id(), ProcessHub.child_id()) :: pid() | nil
  def local_pid(hub_id, child_id) do
    case lookup(hub_id, child_id) do
      nil -> nil
      {_child_spec, node_pids} -> Keyword.get(node_pids, node())
    end
  end

  @doc """
  Returns all children that are running on the local node.

  Returns a map of child_id to {child_spec, node_pids, metadata} tuples
  for all children where the local node has a running process.
  """
  @spec local_children(ProcessHub.hub_id()) :: %{
          ProcessHub.child_id() => {ProcessHub.child_spec(), [{node(), pid()}], metadata()}
        }
  def local_children(hub_id) do
    local_node = node()

    Storage.foldl(hub_id, %{}, fn
      {child_id, {_, nodes, _} = value}, acc ->
        if Keyword.has_key?(nodes, local_node), do: Map.put(acc, child_id, value), else: acc

      {child_id, {_, nodes, _} = value, _ttl}, acc ->
        if Keyword.has_key?(nodes, local_node), do: Map.put(acc, child_id, value), else: acc
    end)
  end

  @doc """
  Checks whether an entry exists in the registry for the given child_id.

  Unlike `lookup/2`, this returns `true` even for entries with empty node lists
  (e.g., pending forwarding entries or TTL tombstone entries).
  """
  @spec entry_exists?(ProcessHub.hub_id(), ProcessHub.child_id()) :: boolean()
  def entry_exists?(hub_id, child_id) do
    Storage.get(hub_id, child_id) != nil
  end

  @doc "Return the child_spec, nodes, and pids for the given child_id."
  @spec lookup(
          ProcessHub.hub_id(),
          ProcessHub.child_id(),
          keyword()
        ) ::
          {ProcessHub.child_spec(), [{node(), pid()}]}
          | {ProcessHub.child_spec(), [{node(), pid()}], ProcessHub.child_metadata()}
          | nil
  def lookup(hub_id, child_id, opts \\ []) do
    table = Keyword.get(opts, :table, hub_id)
    with_metadata = Keyword.get(opts, :with_metadata, false)

    case Storage.get(table, child_id) do
      nil ->
        nil

      {_child_spec, [], _metadata} ->
        nil

      {child_spec, child_nodes, metadata} ->
        case with_metadata do
          true ->
            {child_spec, child_nodes, metadata}

          false ->
            {child_spec, child_nodes}
        end
    end
  end

  @doc """
  Inserts information about a child process into the registry.

  ## Hook Behavior
  This function will dispatch the `:child_registered_hook` hook if the `:hook_storage`
  option is provided. If `:hook_storage` is `nil` or not provided, no hooks will be fired.

  ## Options
  - `:metadata` - Additional metadata to store with the process (default: `%{}`)
  - `:table` - Alternative table to use for storage (default: `hub_id`)
  - `:hook_storage` - Hook storage to use for dispatching hooks (default: `nil`)
  """
  @spec insert(ProcessHub.hub_id(), ProcessHub.child_spec(), [{node(), pid()}], keyword() | nil) ::
          :ok
  def insert(hub_id, child_spec, child_nodes, opts \\ []) do
    GenServer.call(via(hub_id), {:insert, hub_id, child_spec, child_nodes, opts})
  end

  @doc """
  Deletes information about a child process from the registry.

  ## Hook Behavior
  This function will dispatch the `:child_unregistered_hook` hook if the `:hook_storage`
  option is provided. If `:hook_storage` is `nil` or not provided, no hooks will be fired.

  ## Options
  - `:hook_storage` - Hook storage to use for dispatching hooks (default: `nil`)
  """
  @spec delete(ProcessHub.hub_id(), ProcessHub.child_id(), keyword() | nil) :: :ok
  def delete(hub_id, child_id, opts \\ []) do
    GenServer.call(via(hub_id), {:delete, hub_id, child_id, opts})
  end

  @doc """
  Inserts information about multiple child processes into the registry.

  ## Hook Behavior
  This function will dispatch the `:child_registered_hook` hook for each child process
  if the `:hook_storage` option is provided. If `:hook_storage` is `nil` or not provided,
  no hooks will be fired.

  ## Options
  - `:hook_storage` - Hook storage to use for dispatching hooks (default: `nil`)
  - `:timeout` - GenServer call timeout in milliseconds (default: `10_000`)

  ## Parameters
  - `hub_id` - The hub identifier
  - `children` - Map of child_id to {child_spec, node_pids, metadata} tuples
  - `opts` - Options keyword list
  """
  @spec bulk_insert(
          ProcessHub.hub_id(),
          %{
            ProcessHub.child_id() => {ProcessHub.child_spec(), [{node(), pid()}], metadata()}
          },
          keyword()
        ) :: :ok
  def bulk_insert(hub_id, children, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    GenServer.call(via(hub_id), {:bulk_insert, hub_id, children, opts}, timeout)
  end

  @doc """
  Deletes information about multiple child processes from the registry.

  ## Hook Behavior
  This function will dispatch the `:child_unregistered_hook` hook for each child process
  if the `:hook_storage` option is provided. If `:hook_storage` is `nil` or not provided,
  no hooks will be fired.

  ## Options
  - `:hook_storage` - Hook storage to use for dispatching hooks (default: `nil`)
  - `:timeout` - GenServer call timeout in milliseconds (default: `10_000`)

  ## Parameters
  - `hub_id` - The hub identifier
  - `children` - List of child_id with nodes to remove
  - `opts` - Options keyword list
  """
  @spec bulk_delete(
          ProcessHub.hub_id(),
          [{ProcessHub.child_id(), [node()]}],
          keyword()
        ) :: :ok
  def bulk_delete(hub_id, children, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    GenServer.call(via(hub_id), {:bulk_delete, hub_id, children, opts}, timeout)
  end

  @doc """
  Updates the row on the registry.

  ## Hook Behavior
  This function intentionally skips hook dispatching during the update operation to avoid
  duplicate or conflicting hook events. Updates are performed as atomic operations.

  ## Parameters
  The `update_fn` must be a function that accepts 3 parameters containing the existing values:
  - `child_spec` - the child specification in map format.
  - `node_pids` - a keyword list containing a list of node pid pairs. Example: `[{:mynode, pid()}]`
  - `metadata`- a map containing the additional information.

  The function should return a tuple in the following format: `{child_spec, node_pids, metadata}`
  and those values will be then used to update the row.

  ## Return Values
  - `:ok` - On successful update
  - `{:error, "No child found"}` - If no child is found for the given `child_id`
  - `{:error, "Invalid arguments returned from the update function"}` - If the update function returns invalid data

  ## Important
  Use this function with care as any invalid data may corrupt the registry.
  """
  @spec update(ProcessHub.hub_id(), ProcessHub.child_id(), function()) ::
          :ok | {:error, String.t()}
  def update(hub_id, child_id, update_fn) do
    GenServer.call(via(hub_id), {:update, hub_id, child_id, update_fn})
  end

  defp handle_insert(hub_id, child_spec, child_nodes, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    Keyword.get(opts, :table, hub_id)
    |> Storage.insert(child_spec.id, {child_spec, child_nodes, metadata}, opts)

    hook_storage = Keyword.get(opts, :hook_storage, nil)

    if hook_storage do
      HookManager.dispatch_hook(
        hook_storage,
        Hook.child_registered(),
        %{child_id: child_spec.id, node_pids: child_nodes}
      )
    end

    :ok
  end

  defp handle_clear_all(hub_id) do
    Storage.clear_all(hub_id)
  end

  defp handle_delete(hub_id, child_id, opts) do
    Storage.remove(hub_id, child_id)

    hook_storage = Keyword.get(opts, :hook_storage, nil)

    if hook_storage do
      HookManager.dispatch_hook(hook_storage, Hook.child_unregistered(), %{child_id: child_id})
    end

    :ok
  end

  defp handle_bulk_insert(hub_id, children, opts) do
    hook_storage = Keyword.get(opts, :hook_storage, nil)

    hooks =
      Enum.map(children, fn {child_id, {child_spec, child_nodes, metadata}} ->
        diff =
          case lookup(hub_id, child_id) do
            nil ->
              handle_insert(
                hub_id,
                child_spec,
                child_nodes,
                metadata: metadata
              )

              child_nodes

            {_child_spec, existing_nodes} ->
              merge_insert(
                child_nodes,
                existing_nodes,
                hub_id,
                child_spec,
                metadata: metadata
              )
          end

        if is_list(diff) && length(diff) > 0 do
          {Hook.child_registered(), %{child_id: child_spec.id, node_pids: diff}}
        end
      end)
      |> Enum.filter(&is_tuple/1)

    if hook_storage do
      HookManager.dispatch_hooks(hook_storage, hooks)
    end

    :ok
  end

  defp handle_bulk_delete(hub_id, children, opts) do
    hooks =
      Enum.map(children, fn {child_id, rem_nodes} ->
        case lookup(hub_id, child_id, with_metadata: true) do
          nil ->
            nil

          {child_spec, nodes, metadata} ->
            new_nodes =
              Enum.filter(nodes, fn {node, _pid} ->
                !Enum.member?(rem_nodes, node)
              end)

            if length(new_nodes) > 0 do
              handle_insert(
                hub_id,
                child_spec,
                new_nodes,
                metadata: metadata
              )
            else
              # Keep the entry alive with a TTL instead of deleting immediately.
              # This prevents a race condition where bulk_delete wipes the entry
              # before an incoming PidsRegisterRequest can re-populate it with
              # the new node's data. The TTL ensures cleanup if no re-population
              # occurs.
              handle_insert(
                hub_id,
                child_spec,
                [],
                metadata: metadata,
                ttl: 30_000
              )
            end

            {Hook.child_unregistered(), %{child_id: child_id}}
        end
      end)
      |> Enum.reject(&is_nil/1)

    hook_storage = Keyword.get(opts, :hook_storage, nil)

    if hook_storage do
      HookManager.dispatch_hooks(hook_storage, hooks)
    end

    :ok
  end

  defp handle_update(hub_id, child_id, update_fn) do
    table = hub_id
    opts = [table: table, with_metadata: true, hook_storage: nil]

    case lookup(hub_id, child_id, opts) do
      nil ->
        {:error, "No child found"}

      {child_spec, node_pids, metadata} ->
        {cs, cn, m} = update_fn.(child_spec, node_pids, metadata)
        handle_insert(hub_id, cs, cn, [{:metadata, m} | opts])

        :ok

      _any ->
        {:error, "Invalid arguments returned from the update function"}
    end
  end

  defp merge_insert(nodes_new, nodes_existing, hub_id, child_spec, opts) do
    cond do
      Enum.sort(nodes_new) !== Enum.sort(nodes_existing) ->
        merged_data = Keyword.merge(nodes_existing, nodes_new)

        handle_insert(
          hub_id,
          child_spec,
          merged_data,
          opts
        )

        get_insert_diff(nodes_new, nodes_existing)

      true ->
        nil
    end
  end

  defp get_insert_diff(nodes_new, nodes_existing) do
    Enum.reduce(nodes_new, [], fn {node, pid}, acc ->
      case nodes_existing[node] do
        nil ->
          [{node, pid} | acc]

        existing_pid ->
          if pid !== existing_pid do
            [{node, pid} | acc]
          else
            acc
          end
      end
    end)
  end

  defp via(hub_id) do
    {:via, Registry, {:"hub.#{hub_id}.system_registry", "process_registry"}}
  end
end
