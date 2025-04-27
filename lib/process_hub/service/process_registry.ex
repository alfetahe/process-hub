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

  alias ProcessHub.Utility.Name
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.Storage

  @doc "Returns information about all registered processes. Will be deprecated in the future."
  @spec registry(ProcessHub.hub_id()) :: registry()
  def registry(hub_id) do
    Name.registry(hub_id)
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

  TODO: Add tests for this function.
  """
  @spec dump(ProcessHub.hub_id()) :: registry_dump()
  def dump(hub_id) do
    Name.registry(hub_id)
    |> Storage.export_all()
    |> Enum.map(fn
      {key, values} -> {key, values}
      # TODO: check if ttl used at all.
      {key, values, _ttl} -> {key, values}
    end)
    |> Map.new()
  end

  @spec process_list(atom(), :global | :local) :: [
          {ProcessHub.child_id(), [{node(), pid()}] | pid()}
        ]
  def process_list(hub_id, :global) do
    registry(hub_id)
    |> Enum.map(fn {child_id, {_child_spec, nodes}} ->
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
    Enum.reduce(registry(hub_id), [], fn {child_id, _}, acc ->
      case Enum.member?(child_ids, child_id) do
        true -> [child_id | acc]
        false -> acc
      end
    end)
    |> Enum.reverse()
  end

  @doc "Deletes all objects from the process registry."
  @spec clear_all(ProcessHub.hub_id()) :: boolean()
  def clear_all(hub_id) do
    Storage.clear_all(Name.registry(hub_id))
  end

  @doc "Returns information on all processes that are running on the local node."
  @spec local_data(ProcessHub.hub_id()) :: [
          {ProcessHub.child_id(), {ProcessHub.child_spec(), [{node(), pid()}]}}
        ]
  def local_data(hub_id) do
    local_node = node()

    registry(hub_id)
    |> Enum.filter(fn {_, {_, nodes}} ->
      Enum.member?(Keyword.keys(nodes), local_node)
    end)
  end

  @doc "Returns a list of child specs registered under the local node."
  @spec local_child_specs(ProcessHub.hub_id()) :: [ProcessHub.child_spec()]
  def local_child_specs(hub_id) do
    local_data(hub_id)
    |> Enum.map(fn
      {_, {child_spec, _}} -> child_spec
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
  @spec lookup(ProcessHub.hub_id(), ProcessHub.child_id(), [table: atom()] | nil) ::
          nil | {ProcessHub.child_spec(), [{node(), pid()}]}
  def lookup(hub_id, child_id, opts) do
    table = Keyword.get(opts, :table, Name.registry(hub_id))

    case Storage.get(table, child_id) do
      nil -> nil
      {child_spec, child_nodes} -> {child_spec, child_nodes}
      {child_spec, child_nodes, _metadata} -> {child_spec, child_nodes}
    end
  end

  def lookup(hub_id, child_id) do
    lookup(hub_id, child_id, table: Name.registry(hub_id))
  end

  @doc """
  Inserts information about a child process into the registry.

  Calling this function will dispatch the `:registry_pid_insert_hook` hook unless the `:skip_hooks` option is set to `true`.
  """
  @spec insert(ProcessHub.hub_id(), ProcessHub.child_spec(), [{node(), pid()}], keyword() | nil) ::
          :ok
  def insert(hub_id, child_spec, child_nodes, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    Keyword.get(opts, :table, Name.registry(hub_id))
    |> Storage.insert(child_spec.id, {child_spec, child_nodes, metadata}, opts)

    unless Keyword.get(opts, :skip_hooks, false) do
      HookManager.dispatch_hook(
        hub_id,
        Hook.registry_pid_inserted(),
        {child_spec.id, child_nodes}
      )
    end

    :ok
  end

  @doc """
  Deletes information about a child process from the registry.

  Calling this function will dispatch the `:registry_pid_remove_hook` hook unless the `:skip_hooks` option is set to `true`.
  """
  @spec delete(ProcessHub.hub_id(), ProcessHub.child_id(), keyword() | nil) :: :ok
  def delete(hub_id, child_id, opts \\ []) do
    Keyword.get(opts, :table, Name.registry(hub_id))
    |> Storage.remove(child_id)

    unless Keyword.get(opts, :skip_hooks, false) do
      HookManager.dispatch_hook(hub_id, Hook.registry_pid_removed(), child_id)
    end

    :ok
  end

  @doc """
  Inserts information about multiple child processes into the registry.

  Calling this function will dispatch the `:registry_pid_insert_hook` hook unless the `:skip_hooks` option is set to `true`.
  """
  @spec bulk_insert(ProcessHub.hub_id(), %{
          ProcessHub.child_id() => {ProcessHub.child_spec(), [{node(), pid()}], metadata()}
        }) :: :ok
  def bulk_insert(hub_id, children) do
    table = Name.registry(hub_id)

    hooks =
      Enum.map(children, fn {child_id, {child_spec, child_nodes, metadata}} ->
        diff =
          case lookup(hub_id, child_id, table: table) do
            nil ->
              insert(
                hub_id,
                child_spec,
                child_nodes,
                skip_hooks: true,
                table: table,
                metadata: metadata
              )

              child_nodes

            {_child_spec, existing_nodes} ->
              merge_insert(
                child_nodes,
                existing_nodes,
                hub_id,
                child_spec,
                table,
                metadata
              )
          end

        if is_list(diff) && length(diff) > 0 do
          {Hook.registry_pid_inserted(), {child_spec.id, diff}}
        end
      end)
      |> Enum.filter(&is_tuple/1)

    HookManager.dispatch_hooks(hub_id, hooks)

    :ok
  end

  @doc """
  Deletes information about multiple child processes from the registry.

  Calling this function will dispatch the `:registry_pid_remove_hook` hooks unless
  the `:skip_hooks` option is set to `true`.
  """
  @spec bulk_delete(ProcessHub.hub_id(), %{
          ProcessHub.child_id() => {ProcessHub.child_spec(), [{node(), pid()}]}
        }) :: :ok
  def bulk_delete(hub_id, children) do
    table = Name.registry(hub_id)

    hooks =
      Enum.map(children, fn {child_id, rem_nodes} ->
        case lookup(hub_id, child_id, table: table) do
          nil ->
            nil

          {child_spec, nodes} ->
            new_nodes =
              Enum.filter(nodes, fn {node, _pid} ->
                !Enum.member?(rem_nodes, node)
              end)

            if length(new_nodes) > 0 do
              insert(hub_id, child_spec, new_nodes, skip_hooks: true, table: table)
            else
              delete(hub_id, child_id, skip_hooks: true, table: table)
            end

            {Hook.registry_pid_removed(), {child_id, rem_nodes}}
        end
      end)
      |> Enum.reject(&is_nil/1)

    HookManager.dispatch_hooks(hub_id, hooks)
  end

  defp merge_insert(nodes_new, nodes_existing, hub_id, child_spec, table, metadata) do
    cond do
      Enum.sort(nodes_new) !== Enum.sort(nodes_existing) ->
        merged_data = Keyword.merge(nodes_existing, nodes_new)

        insert(
          hub_id,
          child_spec,
          merged_data,
          skip_hooks: true,
          table: table,
          metadata: metadata
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
