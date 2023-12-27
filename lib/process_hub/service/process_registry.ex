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
      |> Cachex.clear()

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
  @spec lookup(ProcessHub.hub_id(), ProcessHub.child_id(), [table: atom()] | nil) ::
          nil | {ProcessHub.child_spec(), [{node(), pid()}]}
  def lookup(hub_id, child_id, opts) do
    {:ok, result} =
      Keyword.get(opts, :table, Name.registry(hub_id))
      |> Cachex.get(child_id)

    case result do
      nil ->
        nil

      {_child_spec, _nodes} ->
        result
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
    res =
      Cachex.transaction(Name.registry(hub_id), Map.keys(children), fn worker ->
        Enum.map(children, fn {child_id, {child_spec, child_nodes}} ->
          diff =
            case lookup(hub_id, child_id, table: worker) do
              nil ->
                insert(hub_id, child_spec, child_nodes, skip_hooks: true, table: worker)
                child_nodes

              {_child_spec, existing_nodes} ->
                merge_insert(child_nodes, existing_nodes, hub_id, child_spec, worker)
            end

          if is_list(diff) && length(diff) > 0 do
            {Hook.registry_pid_inserted(), {child_spec.id, diff}}
          else
            nil
          end
        end)
        |> Enum.filter(&is_tuple/1)
      end)

    # TODO:
    hooks =
      case res do
        {:ok, hooks} -> hooks
        {:error, reason} -> raise reason
      end

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
    {:ok, hooks} =
      Cachex.transaction(Name.registry(hub_id), Map.keys(children), fn worker ->
        Enum.map(children, fn {child_id, rem_nodes} ->
          case lookup(hub_id, child_id, table: worker) do
            nil ->
              nil

            {child_spec, nodes} ->
              new_nodes =
                Enum.filter(nodes, fn {node, _pid} ->
                  !Enum.member?(rem_nodes, node)
                end)

              if length(new_nodes) > 0 do
                insert(hub_id, child_spec, new_nodes, skip_hooks: true, table: worker)
              else
                delete(hub_id, child_id, skip_hooks: true, table: worker)
              end

              {Hook.registry_pid_removed(), {child_id, rem_nodes}}
          end
        end)
        |> Enum.reject(&is_nil/1)
      end)

    HookManager.dispatch_hooks(hub_id, hooks)
  end

  defp merge_insert(nodes_new, nodes_existing, hub_id, child_spec, worker) do
    cond do
      Enum.sort(nodes_new) !== Enum.sort(nodes_existing) ->
        merged_data = Keyword.merge(nodes_existing, nodes_new)
        insert(hub_id, child_spec, merged_data, skip_hooks: true, table: worker)
        insert_diff(nodes_new, nodes_existing)

      true ->
        nil
    end
  end

  defp insert_diff(nodes_new, nodes_existing) do
    Enum.reduce(nodes_new, [], fn {node, pid}, acc ->
      case nodes_existing[node] do
        nil ->
          [{node, pid} | acc]

        {_existing_node, existing_pid} ->
          if pid !== existing_pid do
            [{node, pid} | acc]
          else
            acc
          end
      end
    end)
  end
end
