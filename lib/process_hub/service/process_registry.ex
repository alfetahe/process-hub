defmodule ProcessHub.Service.ProcessRegistry do
  @moduledoc """
  The process registry service provides API functions for managing the process registry.
  """

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

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Storage

  @doc "Returns information about all registered processes. Will be deprecated in the future."
  @spec registry(ProcessHub.hub_id()) :: registry()
  def registry(hub_id) do
    hub_id
    |> Storage.export_all()
    |> Enum.map(fn
      {key, {c, n, _m}} -> {key, {c, n}}
      {key, {c, n, _m}, _ttl} -> {key, {c, n}}
    end)
    |> Map.new()
  end

  @doc """
  Dumps the whole registry.

  Returns all information about all registered processes including metadata.
  """
  @spec dump(ProcessHub.hub_id()) :: registry_dump()
  def dump(hub_id) do
    hub_id
    |> Storage.export_all()
    |> Enum.map(fn
      {key, values} -> {key, values}
    end)
    |> Map.new()
  end

  @spec process_list(atom(), :global | :local) :: [
          {ProcessHub.child_id(), [{node(), pid()}] | pid()}
        ]
  def process_list(hub_id, :global) do
    dump(hub_id)
    |> Enum.map(fn {child_id, {_child_spec, nodes, _metadata}} ->
      {child_id, nodes}
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
    Enum.reduce(dump(hub_id), [], fn {child_id, _}, acc ->
      case Enum.member?(child_ids, child_id) do
        true -> [child_id | acc]
        false -> acc
      end
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
    Storage.clear_all(hub_id)
  end

  @doc "Returns information on all processes that are running on the local node."
  @spec local_data(ProcessHub.hub_id()) :: [
          {ProcessHub.child_id(), {ProcessHub.child_spec(), [{node(), pid()}]}}
        ]
  def local_data(hub_id) do
    local_node = node()

    dump(hub_id)
    |> Enum.filter(fn {_, {_, nodes, _}} ->
      Enum.member?(Keyword.keys(nodes), local_node)
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

  @doc "Return the child_spec, nodes, and pids for the given child_id."
  @spec lookup(
          ProcessHub.hub_id(),
          ProcessHub.child_id(),
          keyword()
        ) ::
          {ProcessHub.child_spec(), [{node(), pid()}]}
          | {ProcessHub.child_spec(), [{node(), pid()}], ProcessHub.child_metadata()}
          | nil
  def lookup(hub_id, child_id, opts) do
    table = Keyword.get(opts, :table, hub_id)
    with_metadata = Keyword.get(opts, :with_metadata, false)

    case Storage.get(table, child_id) do
      nil ->
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

  def lookup(hub_id, child_id) do
    lookup(hub_id, child_id, table: hub_id)
  end

  @doc """
  Inserts information about a child process into the registry.

  ## Hook Behavior
  This function will dispatch the `:registry_pid_insert_hook` hook if the `:hook_storage`
  option is provided. If `:hook_storage` is `nil` or not provided, no hooks will be fired.

  ## Options
  - `:metadata` - Additional metadata to store with the process (default: `%{}`)
  - `:table` - Alternative table to use for storage (default: `hub_id`)
  - `:hook_storage` - Hook storage to use for dispatching hooks (default: `nil`)
  """
  @spec insert(ProcessHub.hub_id(), ProcessHub.child_spec(), [{node(), pid()}], keyword() | nil) ::
          :ok
  def insert(hub_id, child_spec, child_nodes, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    Keyword.get(opts, :table, hub_id)
    |> Storage.insert(child_spec.id, {child_spec, child_nodes, metadata}, opts)

    hook_storage = Keyword.get(opts, :hook_storage, nil)

    if hook_storage do
      # TODO: add back for testing dbg({"PID SOLO INSERT", node(), child_spec.id, child_nodes})

      HookManager.dispatch_hook(
        hook_storage,
        Hook.registry_pid_inserted(),
        {child_spec.id, child_nodes}
      )
    end

    :ok
  end

  @doc """
  Deletes information about a child process from the registry.

  ## Hook Behavior
  This function will dispatch the `:registry_pid_remove_hook` hook if the `:hook_storage`
  option is provided. If `:hook_storage` is `nil` or not provided, no hooks will be fired.

  ## Options
  - `:hook_storage` - Hook storage to use for dispatching hooks (default: `nil`)
  """
  @spec delete(ProcessHub.hub_id(), ProcessHub.child_id(), keyword() | nil) :: :ok
  def delete(hub_id, child_id, opts \\ []) do
    Storage.remove(hub_id, child_id)

    hook_storage = Keyword.get(opts, :hook_storage, nil)

    if hook_storage do
      HookManager.dispatch_hook(hook_storage, Hook.registry_pid_removed(), child_id)
    end

    :ok
  end

  @doc """
  Inserts information about multiple child processes into the registry.

  ## Hook Behavior
  This function will dispatch the `:registry_pid_insert_hook` hook for each child process
  if the `:hook_storage` option is provided. If `:hook_storage` is `nil` or not provided,
  no hooks will be fired.

  ## Options
  - `:hook_storage` - Hook storage to use for dispatching hooks (default: `nil`)

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
    hook_storage = Keyword.get(opts, :hook_storage, nil)

    hooks =
      Enum.map(children, fn {child_id, {child_spec, child_nodes, metadata}} ->
        diff =
          case lookup(hub_id, child_id) do
            nil ->
              insert(
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
          # TODO: add back for testing  dbg({"PID BULK INSERT", node(), child_spec.id, diff})
          {Hook.registry_pid_inserted(), {child_spec.id, diff}}
        end
      end)
      |> Enum.filter(&is_tuple/1)

    if hook_storage do
      HookManager.dispatch_hooks(hook_storage, hooks)
    end

    :ok
  end

  @doc """
  Deletes information about multiple child processes from the registry.

  ## Hook Behavior
  This function will dispatch the `:registry_pid_remove_hook` hook for each child process
  if the `:hook_storage` option is provided. If `:hook_storage` is `nil` or not provided,
  no hooks will be fired.

  ## Options
  - `:hook_storage` - Hook storage to use for dispatching hooks (default: `nil`)

  ## Parameters
  - `hub_id` - The hub identifier
  - `children` - Map of child_id to list of nodes to remove
  - `opts` - Options keyword list
  """
  @spec bulk_delete(
          ProcessHub.hub_id(),
          %{
            ProcessHub.child_id() => {ProcessHub.child_spec(), [{node(), pid()}]}
          },
          keyword()
        ) :: :ok
  def bulk_delete(hub_id, children, opts \\ []) do
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
              insert(
                hub_id,
                child_spec,
                new_nodes,
                metadata: metadata
              )
            else
              delete(hub_id, child_id)
            end

            {Hook.registry_pid_removed(), {child_id, rem_nodes}}
        end
      end)
      |> Enum.reject(&is_nil/1)

    hook_storage = Keyword.get(opts, :hook_storage, nil)

    if hook_storage do
      HookManager.dispatch_hooks(hook_storage, hooks)
    end

    :ok
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
    table = hub_id
    opts = [table: table, with_metadata: true, skip_hooks: true]

    case lookup(hub_id, child_id, opts) do
      nil ->
        {:error, "No child found"}

      {child_spec, node_pids, metadata} ->
        {cs, cn, m} = update_fn.(child_spec, node_pids, metadata)
        insert(hub_id, cs, cn, [{:metadata, m} | opts])

        :ok

      _any ->
        {:error, "Invalid arguments returned from the update function"}
    end
  end

  defp merge_insert(nodes_new, nodes_existing, hub_id, child_spec, opts) do
    cond do
      Enum.sort(nodes_new) !== Enum.sort(nodes_existing) ->
        merged_data = Keyword.merge(nodes_existing, nodes_new)

        insert(
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
end
