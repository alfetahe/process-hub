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

  alias ProcessHub.Utility.Name
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager

  @doc "Returns information about all registered processes."
  @spec registry(ProcessHub.hub_id()) :: registry()
  def registry(hub_id) do
    Name.registry(hub_id)
    |> Cachex.export()
    |> elem(1)
    |> Enum.map(fn {:entry, key, _, _, value} -> {key, value} end)
    |> Map.new()
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
  @spec clear_all(ProcessHub.hub_id()) :: integer()
  def clear_all(hub_id) do
    {:ok, number_of_rows} =
      Name.registry(hub_id)
      |> Cachex.purge()

    number_of_rows
  end

  @doc "Returns information about processes registered under the local node."
  @spec local_children(ProcessHub.hub_id()) :: [
          {ProcessHub.child_id(), {ProcessHub.child_spec(), [{node(), pid()}]}}
        ]
  def local_children(hub_id) do
    local_node = node()

    registry(hub_id)
    |> Enum.filter(fn {_, {_, nodes}} ->
      Enum.member?(Keyword.keys(nodes), local_node)
    end)
  end

  @doc "Returns a list of child specs registered under the local node."
  @spec local_child_specs(ProcessHub.hub_id()) :: [ProcessHub.child_spec()]
  def local_child_specs(hub_id) do
    local_children(hub_id)
    |> Enum.map(fn {_, {child_spec, _}} -> child_spec end)
  end

  @doc "Return the child_spec, nodes, and pids for the given child_id."
  @spec lookup(ProcessHub.hub_id(), ProcessHub.child_id()) ::
          nil | {ProcessHub.child_spec(), [{node(), pid()}]}
  def lookup(hub_id, child_id) do
    {:ok, result} =
      Name.registry(hub_id)
      |> Cachex.get(child_id)

    case result do
      nil ->
        nil

      {_child_spec, _nodes} ->
        result
    end
  end

  @doc """
  Inserts information about a child process into the registry.

  Calling this function will dispatch the `:registry_pid_insert_hook` hook unless the `:skip_hooks` option is set to `true`.
  """
  @spec insert(ProcessHub.hub_id(), ProcessHub.child_spec(), [{node(), pid()}], keyword() | nil) ::
          :ok
  def insert(hub_id, child_spec, child_nodes, opts \\ []) do
    Keyword.get(opts, :table, Name.registry(hub_id))
    |> Cachex.put(child_spec.id, {child_spec, child_nodes})

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
    |> Cachex.del(child_id)

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
          ProcessHub.child_id() => {ProcessHub.child_spec(), [{node(), pid()}]}
        }) :: :ok
  def bulk_insert(hub_id, children) do
    registry_table = Name.registry(hub_id)
    process_registry = registry(hub_id)

    hooks =
      Enum.map(children, fn {child_id, {child_spec, child_nodes}} ->
        inserted =
          case process_registry[child_id] do
            nil ->
              insert(hub_id, child_spec, child_nodes, skip_hooks: true, table: registry_table)
              child_nodes

            {_child_spec, nodes} ->
              new_nodes = Enum.uniq(nodes ++ child_nodes)
              insert(hub_id, child_spec, new_nodes, skip_hooks: true, table: registry_table)
              new_nodes
          end

        {Hook.registry_pid_inserted(), {child_spec.id, inserted}}
      end)

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
    registry_table = Name.registry(hub_id)
    process_registry = registry(hub_id)

    hooks =
      Enum.map(children, fn {child_id, rem_nodes} ->
        case process_registry[child_id] do
          nil ->
            nil

          {child_spec, nodes} ->
            new_nodes =
              Enum.filter(nodes, fn {node, _pid} ->
                !Enum.member?(rem_nodes, node)
              end)

            if length(new_nodes) > 0 do
              insert(hub_id, child_spec, new_nodes, skip_hooks: true, table: registry_table)
            else
              delete(hub_id, child_id, skip_hooks: true, table: registry_table)
            end

            {Hook.registry_pid_removed(), {child_id, rem_nodes}}
        end
      end)
      |> Enum.reject(&is_nil/1)

    HookManager.dispatch_hooks(hub_id, hooks)
  end
end
