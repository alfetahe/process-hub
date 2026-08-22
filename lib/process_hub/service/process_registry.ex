defmodule ProcessHub.Service.ProcessRegistry do
  @moduledoc """
  The process registry service provides API functions for managing the process registry.
  """

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.Batch
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.ProcessRegistry.Row
  alias ProcessHub.Service.Storage

  require Logger

  use GenServer

  @default_timeout 10_000

  # Registry writes are applied on the spot and synced in a group: see `commit/4`.
  @deferred [sync: false]
  # Per-peer budget for opt-in update propagation. Kept short: propagation
  # runs in the caller (e.g. inside a heal/rebind path) and is best-effort —
  # a slow peer must not stall the caller for the full local timeout.
  @propagate_timeout 2_000

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
          optional(:tag) => String.t(),
          optional(:__process_hub__) => Row.t()
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
    {:ok, %{hub_id: hub_id, batch: Batch.new(), dirty: MapSet.new()}}
  end

  @impl GenServer
  def handle_call({:insert, _hub_id, child_spec, child_nodes, opts}, from, state) do
    table = Keyword.get(opts, :table, state.hub_id)

    commit(
      state,
      from,
      table,
      with_storage(fn -> handle_insert(state, child_spec, child_nodes, opts) end)
    )
  end

  @impl GenServer
  def handle_call({:delete, hub_id, child_id, opts}, from, state) do
    commit(state, from, hub_id, with_storage(fn -> handle_delete(hub_id, child_id, opts) end))
  end

  @impl GenServer
  def handle_call({:bulk_insert, _hub_id, children, opts}, from, state) do
    commit(
      state,
      from,
      state.hub_id,
      with_storage(fn -> handle_bulk_insert(state, children, opts) end)
    )
  end

  @impl GenServer
  def handle_call({:bulk_delete, _hub_id, children, opts}, from, state) do
    commit(
      state,
      from,
      state.hub_id,
      with_storage(fn -> handle_bulk_delete(state, children, opts) end)
    )
  end

  @impl GenServer
  def handle_call({:update, _hub_id, child_id, update_fn}, from, state) do
    commit(
      state,
      from,
      state.hub_id,
      with_storage(fn -> handle_update(state, child_id, update_fn) end)
    )
  end

  @impl GenServer
  def handle_call({:clear_all, hub_id}, _from, state) do
    {:reply, with_storage(fn -> handle_clear_all(hub_id) end), state}
  end

  @impl GenServer
  def handle_call({:delete_if_expired, hub_id, child_id}, from, state) do
    commit(
      state,
      from,
      hub_id,
      with_storage(fn -> handle_delete_if_expired(hub_id, child_id) end, false)
    )
  end

  # One durable sync per dirty table covers every write queued ahead of this
  # message, then each caller gets its reply. A sync failure is reported, not
  # turned into a caller error: the rows are already applied, and the backend
  # syncs again on the next write.
  @impl GenServer
  def handle_info(:flush, state) do
    Enum.each(state.dirty, fn table ->
      case with_storage(fn -> Storage.sync(table) end) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "ProcessRegistry: durable sync of #{inspect(table)} failed: #{inspect(reason)}"
          )
      end
    end)

    {replies, batch} = Batch.take(state.batch)
    Enum.each(replies, fn {from, result} -> GenServer.reply(from, result) end)

    {:noreply, %{state | batch: batch, dirty: MapSet.new()}}
  end

  # The catch-all `use GenServer` provided before `:flush` existed: a stray
  # message (a late reply to a call made from inside a hook) is noted, never
  # fatal to the registry.
  @impl GenServer
  def handle_info(message, state) do
    Logger.debug("ProcessRegistry received an unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # Group commit. The write is applied before this runs; its reply rides the
  # next `:flush`, which is queued once and lands behind every request already
  # in the mailbox — so concurrent callers share one sync instead of paying
  # one each, and no caller is answered before the sync that covers its write.
  # A result that wrote nothing (an error, a no-op expiry) is answered at once.
  defp commit(state, from, table, result) when result in [:ok, true] do
    {:noreply,
     %{
       state
       | batch: Batch.add(state.batch, :flush, {from, result}),
         dirty: MapSet.put(state.dirty, table)
     }}
  end

  defp commit(state, _from, _table, result), do: {:reply, result, state}

  # Drops mutation requests that race against hub teardown: Coordinator.terminate
  # closes the registry backend, so a still-queued bulk_delete/insert can land
  # after the ETS table is gone and crash on `:ets.insert/2`.
  defp with_storage(fun, fallback \\ :ok) do
    try do
      fun.()
    rescue
      ArgumentError -> fallback
    end
  end

  @doc "Returns information about all registered processes. Deprecated, use `dump/1` instead."
  @spec registry(ProcessHub.hub_id()) :: registry()
  def registry(hub_id) do
    hub_id
    |> dump()
    |> Map.new(fn {child_id, {child_spec, nodes, _metadata}} ->
      {child_id, {child_spec, nodes}}
    end)
  end

  @doc """
  Dumps the whole registry.

  Returns all information about all registered processes including metadata.
  Entries with empty node lists are excluded.
  """
  @spec dump(ProcessHub.hub_id()) :: registry_dump()
  def dump(hub_id), do: dump_all(hub_id, include_unbound: false)

  @doc """
  Dumps the whole registry including entries with empty node lists.

  Unlike `dump/1`, this includes all entries regardless of their node list,
  such as pending forwarding entries and churn stubs.

  ## Options
  - `:include_unbound` - when `false`, rows with an empty node list are left out
    (default: `true`). This is what `dump/1` asks for.
  """
  @spec dump_all(ProcessHub.hub_id(), keyword()) :: registry_dump()
  def dump_all(hub_id, opts \\ []) do
    include_unbound = Keyword.get(opts, :include_unbound, true)

    Storage.foldl_entries(hub_id, %{}, fn {child_id, {_spec, nodes, _metadata} = value}, acc ->
      if not include_unbound and nodes === [] do
        acc
      else
        Map.put(acc, child_id, value)
      end
    end)
  end

  @spec process_list(atom(), :global | :local) :: [
          {ProcessHub.child_id(), [{node(), pid()}] | pid()}
        ]
  def process_list(hub_id, :global) do
    Storage.foldl_entries(hub_id, [], fn
      {child_id, {_child_spec, nodes, _metadata}}, acc when nodes != [] ->
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

    Storage.foldl_entries(hub_id, [], fn
      {_child_id, {_spec, [], _meta}}, acc ->
        acc

      {child_id, _}, acc ->
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

  @doc """
  Returns every child whose registry metadata carries `key`, with that key's
  value: `[{child_id, node_pids, value}]`. An ETS match over the rows, no row
  decoding — `match_tag/2` generalised to any metadata key and any value.
  """
  @spec match_metadata(ProcessHub.hub_id(), term()) :: [
          {ProcessHub.child_id(), [{node(), pid()}], term()}
        ]
  def match_metadata(hub_id, key) do
    Storage.match(hub_id, {:"$1", {:_, :"$2", %{key => :"$3"}}})
  end

  @doc "Deletes all objects from the process registry."
  @spec clear_all(ProcessHub.hub_id()) :: boolean()
  def clear_all(hub_id) do
    GenServer.call(via(hub_id), {:clear_all, hub_id})
  end

  @doc "Returns information on all processes that are running on the local node."
  @spec local_data(ProcessHub.hub_id()) :: [
          {ProcessHub.child_id(), {ProcessHub.child_spec(), [{node(), pid()}]}}
        ]
  def local_data(hub_id) do
    local_node = node()

    Storage.foldl_entries(hub_id, [], fn
      {child_id, {_, nodes, _} = value}, acc ->
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
    hub_id
    |> local_data()
    |> Map.new()
  end

  @doc """
  Checks whether an entry exists in the registry for the given child_id.

  Unlike `lookup/2`, this returns `true` even for entries with empty node lists
  (e.g., pending forwarding entries or churn stubs).
  """
  @spec entry_exists?(ProcessHub.hub_id(), ProcessHub.child_id()) :: boolean()
  def entry_exists?(hub_id, child_id) do
    Storage.get(hub_id, child_id) != nil
  end

  @doc """
  Return the child_spec, nodes, and pids for the given child_id.

  ## Options
  - `:table` - alternative table to read from (default: `hub_id`)
  - `:with_metadata` - include the metadata map in the returned tuple (default: `false`)
  - `:include_empty` - also return rows whose `node_pids` list is empty —
    pending-forward rows and rows whose last observation was withdrawn
    (default: `false`, which reports them as absent)
  """
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
    include_empty = Keyword.get(opts, :include_empty, false)

    case Storage.get(table, child_id) do
      nil ->
        nil

      {_child_spec, [], _metadata} when not include_empty ->
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
  - `:metadata` - Additional metadata to store with the process (default: `%{}`).
    The reserved `:__process_hub__` key is hub-owned: a caller-supplied value is
    ignored with a WARN log.
  - `:table` - Alternative table to use for storage (default: `hub_id`)
  - `:hook_storage` - Hook storage to use for dispatching hooks (default: `nil`)
  - `:adopt` - When `true`, the `:__process_hub__` map inside `:metadata` is
    written verbatim instead of being re-authored. Reserved for the replica merge,
    which adopts the winner of an epoch comparison rather than authoring a new
    value (default: `false`).
  - `:durable` - Marks the row's child as declared (`durable: true` start); the
    flag is carried in the hub-owned bookkeeping and survives subsequent writes.
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

  Rows are never removed here — only the named nodes' entries are.

  ## Options
  - `:hook_storage` - Hook storage to use for dispatching hooks (default: `nil`)
  - `:timeout` - GenServer call timeout in milliseconds (default: `10_000`)
  - `:on_empty` - what becomes of a row that just lost its last node entry:
    - `:churn` (default) - a stub with a 30 s expiry. For placement churn, where
      a re-registration from the child's new node is expected imminently.
    - `:delete` - the row is removed entirely, for a deliberate stop. Stop
      memory for declared children lives in the declared list, not in the row.
    - `:keep` - an unbound row with no expiry, for a withdrawn observation.
      The row is kept rather than erased on someone else's say-so.

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
  Withdraws every `{node, pid}` observation in `registry` for which
  `withdraw?.(child_id, node)` returns true. Returns the affected child_ids.

  Withdrawing is never a delete: an observation says only what its owner sees, so
  a child left with no observation keeps its row (`on_empty: :keep`) and becomes a
  candidate for the next orphan reconcile round rather than being erased on
  someone else's say-so.

  `opts` are forwarded to `bulk_delete/3`.
  """
  @spec withdraw_observations(
          ProcessHub.hub_id(),
          registry_dump(),
          (ProcessHub.child_id(), node() -> boolean()),
          keyword()
        ) :: [ProcessHub.child_id()]
  def withdraw_observations(hub_id, registry, withdraw?, opts \\ []) do
    withdrawn =
      registry
      |> Enum.map(fn {child_id, {_child_spec, node_pids, _metadata}} ->
        {child_id, node_pids |> Keyword.keys() |> Enum.filter(&withdraw?.(child_id, &1))}
      end)
      |> Enum.reject(fn {_child_id, nodes} -> nodes === [] end)

    if withdrawn !== [] do
      bulk_delete(hub_id, withdrawn, Keyword.put(opts, :on_empty, :keep))
    end

    Enum.map(withdrawn, fn {child_id, _nodes} -> child_id end)
  end

  @doc """
  Deletes a TTL registry entry, but only if it is still expired.

  Expiry is re-validated inside the registry process. If the entry was
  re-populated since the caller observed it (re-population clears the TTL,
  turning the row into a permanent 2-tuple) or was given a fresh TTL lease,
  the delete is skipped. This closes a race where the janitor's registry
  scan sees an expired stub, but an incoming registration re-populates
  the entry before the delete is applied — without this guard the cleanup
  would wipe a freshly re-registered live process.

  Returns `true` if the entry was removed, `false` otherwise.
  """
  @spec delete_if_expired(ProcessHub.hub_id(), ProcessHub.child_id()) :: boolean()
  def delete_if_expired(hub_id, child_id) do
    GenServer.call(via(hub_id), {:delete_if_expired, hub_id, child_id})
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

  ## Options
  - `:propagate` - When `true`, after the local update succeeds the same
    `update_fn` is applied on every other hub node's registry (best-effort:
    unreachable peers are logged and skipped; they converge on rejoin via
    peer sync; each peer call is bounded to 2s so a slow peer cannot stall
    the caller). Each peer applies the function to its own current row, so
    the function must be pure and convergent. Defaults to `false` — plain
    updates stay node-local (node-down purging relies on that).
  - `:timeout` - local GenServer call timeout in milliseconds (default: `10_000`)

  ## Return Values
  - `:ok` - On successful update
  - `{:error, "No child found"}` - If no child is found for the given `child_id`
  - `{:error, "Invalid arguments returned from the update function"}` - If the update function returns invalid data

  ## Important
  Use this function with care as any invalid data may corrupt the registry.
  """
  @spec update(ProcessHub.hub_id(), ProcessHub.child_id(), function(), keyword()) ::
          :ok | {:error, String.t()}
  def update(hub_id, child_id, update_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    result = GenServer.call(via(hub_id), {:update, hub_id, child_id, update_fn}, timeout)

    if result == :ok and Keyword.get(opts, :propagate, false) do
      propagate_update(hub_id, child_id, update_fn, @propagate_timeout)
    end

    result
  end

  # Re-apply `update_fn` on every other hub node so durable child_spec or
  # metadata edits survive a restart driven from any node's registry copy.
  defp propagate_update(hub_id, child_id, update_fn, timeout) do
    ProcessHub.nodes(hub_id)
    |> Enum.each(fn node ->
      try do
        case :erpc.call(
               node,
               GenServer,
               :call,
               [via(hub_id), {:update, hub_id, child_id, update_fn}, timeout],
               timeout
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "ProcessRegistry update propagation rejected on #{inspect(node)} " <>
                "for #{inspect(child_id)}: #{inspect(reason)}"
            )
        end
      catch
        kind, reason ->
          Logger.warning(
            "ProcessRegistry update propagation failed on #{inspect(node)} " <>
              "for #{inspect(child_id)}: #{inspect(kind)} #{inspect(reason)}"
          )
      end
    end)
  end

  defp handle_insert(state, child_spec, child_nodes, opts) do
    table = Keyword.get(opts, :table, state.hub_id)
    row = staged_row(state, table, child_spec.id, child_spec, child_nodes, opts)
    Storage.insert_many(table, [row], @deferred)

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

  defp handle_delete_if_expired(hub_id, child_id) do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    case Storage.match(hub_id, {child_id, :_, :"$1"}) do
      [{expire}] when is_integer(expire) and now > expire ->
        Storage.remove(hub_id, child_id, @deferred)
        true

      _ ->
        # Entry was re-populated (TTL cleared) or re-leased since the scan; keep it.
        false
    end
  end

  defp handle_delete(hub_id, child_id, opts) do
    Storage.remove(hub_id, child_id, @deferred)

    hook_storage = Keyword.get(opts, :hook_storage, nil)

    if hook_storage do
      HookManager.dispatch_hook(hook_storage, Hook.child_unregistered(), %{child_id: child_id})
    end

    :ok
  end

  # Stages all final rows first and commits them with a single
  # `Storage.insert_many/2` write, so concurrent readers never observe a
  # partially applied bulk.
  defp handle_bulk_insert(state, children, opts) do
    hook_storage = Keyword.get(opts, :hook_storage, nil)
    hub_id = state.hub_id

    {rows, hooks} =
      Enum.reduce(children, {[], []}, fn {child_id, {child_spec, child_nodes, metadata}},
                                         {rows, hooks} ->
        case lookup(hub_id, child_id, with_metadata: true, include_empty: true) do
          nil ->
            row =
              staged_row(
                state,
                hub_id,
                child_id,
                child_spec,
                child_nodes,
                Keyword.put(opts, :metadata, metadata)
              )

            {[row | rows], stage_registered_hook(hooks, child_id, child_nodes)}

          {_child_spec, existing_nodes, _existing_metadata} ->
            if Enum.sort(child_nodes) !== Enum.sort(existing_nodes) do
              merged_nodes = Keyword.merge(existing_nodes, child_nodes)
              diff = get_insert_diff(child_nodes, existing_nodes)

              row =
                staged_row(
                  state,
                  hub_id,
                  child_id,
                  child_spec,
                  merged_nodes,
                  Keyword.put(opts, :metadata, metadata)
                )

              {[row | rows], stage_registered_hook(hooks, child_id, diff)}
            else
              {rows, hooks}
            end
        end
      end)

    Storage.insert_many(hub_id, rows, @deferred)

    if hook_storage do
      HookManager.dispatch_hooks(hook_storage, Enum.reverse(hooks))
    end

    :ok
  end

  defp stage_registered_hook(hooks, _child_id, []), do: hooks

  defp stage_registered_hook(hooks, child_id, node_pids) do
    [{Hook.child_registered(), %{child_id: child_id, node_pids: node_pids}} | hooks]
  end

  # Same stage-then-commit shape as `handle_bulk_insert/3`. Rows emptied under
  # `on_empty: :delete` are removed instead of re-staged.
  defp handle_bulk_delete(state, children, opts) do
    hub_id = state.hub_id
    on_empty = Keyword.get(opts, :on_empty) || :churn

    {rows, deletes, hooks} =
      Enum.reduce(children, {[], [], []}, fn {child_id, rem_nodes}, {rows, deletes, hooks} ->
        case lookup(hub_id, child_id, with_metadata: true) do
          nil ->
            {rows, deletes, hooks}

          {child_spec, nodes, metadata} ->
            new_nodes =
              Enum.filter(nodes, fn {node, _pid} ->
                !Enum.member?(rem_nodes, node)
              end)

            hooks = [{Hook.child_unregistered(), %{child_id: child_id}} | hooks]

            if new_nodes === [] and on_empty === :delete do
              {rows, [child_id | deletes], hooks}
            else
              row_opts = if new_nodes != [], do: [], else: empty_row_opts(on_empty)

              row =
                staged_row(
                  state,
                  hub_id,
                  child_id,
                  child_spec,
                  new_nodes,
                  Keyword.put(row_opts, :metadata, metadata)
                )

              {[row | rows], deletes, hooks}
            end
        end
      end)

    Storage.insert_many(hub_id, rows, @deferred)
    Enum.each(deletes, &Storage.remove(hub_id, &1, @deferred))
    hooks = Enum.reverse(hooks)

    hook_storage = Keyword.get(opts, :hook_storage, nil)

    if hook_storage do
      HookManager.dispatch_hooks(hook_storage, hooks)
    end

    :ok
  end

  defp handle_update(state, child_id, update_fn) do
    opts = [table: state.hub_id, with_metadata: true, hook_storage: nil]

    case lookup(state.hub_id, child_id, opts) do
      nil ->
        {:error, "No child found"}

      {child_spec, node_pids, metadata} ->
        {cs, cn, m} = update_fn.(child_spec, node_pids, metadata)
        handle_insert(state, cs, cn, [{:metadata, m} | opts])

        :ok

      _any ->
        {:error, "Invalid arguments returned from the update function"}
    end
  end

  ## Row bookkeeping ---------------------------------------------------------

  # The churn expiry closes a race where a bulk_delete would wipe the entry
  # before the new node's PidsRegisterRequest re-populates it.
  defp empty_row_opts(:churn), do: [ttl: 30_000]
  defp empty_row_opts(:keep), do: []

  # The single row builder: every write stamps its bookkeeping here, whether it
  # is committed alone or in a bulk.
  defp staged_row(state, table, child_id, child_spec, child_nodes, opts) do
    metadata = stamped_metadata(state, table, child_id, opts)

    {child_id, {child_spec, child_nodes, metadata}, Keyword.take(opts, [:ttl, :expire_at])}
  end

  defp stamped_metadata(state, table, child_id, opts) do
    previous =
      case Storage.get(table, child_id) do
        {_child_spec, _child_nodes, previous_metadata} -> Row.meta(previous_metadata)
        _ -> nil
      end

    {metadata, forged?} =
      Row.stamp(Keyword.get(opts, :metadata, %{}), previous, opts)

    if forged?, do: warn_reserved_write(state.hub_id, child_id)

    metadata
  end

  defp warn_reserved_write(hub_id, child_id) do
    Logger.warning(
      "ProcessHub registry: ignoring caller-supplied #{inspect(Row.reserved_key())} metadata " <>
        "for #{inspect(child_id)} on #{inspect(hub_id)}; the key is hub-owned."
    )
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
