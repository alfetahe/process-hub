defmodule ProcessHub.Service.DeclaredChildren do
  @moduledoc """
  The declared list: a versioned, durable, leader-written list of the children
  that SHALL exist on a hub.

  > #### Experimental {: .warning}
  >
  > The declared-children feature is experimental and may change in future
  > releases. Use in production at your own discretion.

  `start_child/3` with `durable: true` adds the child's spec, a deliberate stop
  removes it, and nothing else writes it — list absence is the stop record and
  never expires. Mutations serialize through the hub's leader (`:elector`,
  with the lowest hub member as deterministic fallback), which bumps one
  version per mutation; adoption replaces the whole list, higher version wins.
  The list commits before the process action, so the orphan reconcile heals a
  crashed command in the next round.

  The list persists in its own DETS-backed store beside the registry, is
  cached in misc storage for reads, and optionally ships to an off-cluster
  `ProcessHub.Storage.RemoteManifest`. A missing or corrupt list with durable
  evidence behind it parks the reconcile instead of opening empty; `clear/1`
  is the operator override. See `guides/Persistence.md` for the full model.
  """

  alias :elector, as: Elector
  alias ProcessHub.Constant.Event
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Dispatcher
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.LoggerService
  alias ProcessHub.Service.DeclaredChildren.Boot
  alias ProcessHub.Service.DeclaredChildren.Store
  alias ProcessHub.Service.Batch
  alias ProcessHub.Service.Storage
  alias ProcessHub.Coordinator.State
  alias ProcessHub.Hub

  use Event

  @format 1
  @mutate_timeout 5_000

  @typedoc "A change to the declared list, applied by the leader."
  @type mutation() :: {:add, [ProcessHub.child_spec()]} | {:remove, [ProcessHub.child_id()]}

  @typedoc """
  A precommit's answer: run the command now, park it behind the batch's write,
  ask the remote `leader` (answering `unreachable` when it cannot be reached),
  or refuse it.
  """
  @type precommit() ::
          :ok
          | {:pending, manifest()}
          | {:remote, node(), mutation(), :ok | {:error, :no_leader}}
          | {:error, term()}

  @typedoc "A command held back by its precommit; it answers its caller."
  @type command() :: (State.t() -> {:reply, term(), State.t()})

  @typedoc "The declared list with its version lineage, as persisted and shipped."
  @type manifest() :: %{
          format: pos_integer(),
          version: non_neg_integer(),
          mutated_by: node(),
          entries: %{ProcessHub.child_id() => ProcessHub.child_spec()}
        }

  @doc "The manifest wire/storage format this release reads and writes."
  @spec format() :: pos_integer()
  def format, do: @format

  @doc "Builds a manifest at `version` with `entries`, mutated by this node."
  @spec new_manifest(non_neg_integer(), %{ProcessHub.child_id() => ProcessHub.child_spec()}) ::
          manifest()
  def new_manifest(version, entries) do
    %{format: @format, version: version, mutated_by: node(), entries: entries}
  end

  # --- reads ------------------------------------------------------------------

  @doc """
  Returns the hub's declared children and the list version from local storage.
  A hub without the feature in use returns `%{version: 0, children: []}`.
  """
  @spec declared_children(ProcessHub.hub_id()) :: %{
          version: non_neg_integer(),
          children: [ProcessHub.child_spec()]
        }
  def declared_children(hub_id) do
    case snapshot(hub_id) do
      nil -> %{version: 0, children: []}
      %{version: version, entries: entries} -> %{version: version, children: Map.values(entries)}
    end
  end

  @doc "Returns the full cached manifest, or `nil` when none exists."
  @spec snapshot(ProcessHub.hub_id()) :: manifest() | nil
  def snapshot(hub_id) when is_atom(hub_id) do
    with %Hub{} = hub <- Hub.get(hub_id), do: manifest(hub)
  end

  @doc "Returns whether the hub's reconcile is parked over a lost declared list."
  @spec parked?(Hub.t()) :: boolean()
  def parked?(%Hub{storage: %{misc: misc}}) do
    Storage.get(misc, StorageKey.dclp()) === true
  end

  @doc "Returns the cached manifest read directly from the hub's misc storage."
  @spec manifest(Hub.t()) :: manifest() | nil
  def manifest(%Hub{storage: %{misc: misc}}), do: Storage.get(misc, StorageKey.dcl())

  # --- command precommit ------------------------------------------------------

  @doc """
  Commits the list additions a `durable: true` start requires, before any
  process starts. Refuses when the gate is off, the list is parked, a spec is
  `:temporary`, or no leader is reachable. `:ok` for non-durable starts.
  """
  @spec precommit_start(State.t(), [ProcessHub.child_spec()], keyword()) :: precommit()
  def precommit_start(%State{hub: hub} = state, child_specs, opts) do
    cond do
      not Keyword.get(opts, :durable, false) -> :ok
      not hub.recovery_config.enabled? -> {:error, :durable_requires_auto_recovery}
      parked?(hub) -> {:error, :declared_list_parked}
      not Enum.all?(child_specs, &restartable?/1) -> {:error, :durable_requires_restartable}
      true -> mutate(state, {:add, child_specs})
    end
  end

  @doc """
  Commits the list removals a stop requires, before any child terminates. The
  leader's copy is authoritative; with no leader reachable the stop is refused
  only when the local copy shows a declared child among `child_ids`.
  """
  @spec precommit_stop(State.t(), [ProcessHub.child_id()]) :: precommit()
  def precommit_stop(%State{hub: %Hub{recovery_config: %{enabled?: false}}}, _child_ids), do: :ok

  def precommit_stop(%State{hub: hub} = state, child_ids) do
    locally_declared? =
      case working_manifest(state) do
        nil -> false
        %{entries: entries} -> Enum.any?(child_ids, &Map.has_key?(entries, &1))
      end

    cond do
      parked?(hub) and locally_declared? -> {:error, :declared_list_parked}
      parked?(hub) -> :ok
      locally_declared? -> mutate(state, {:remove, child_ids})
      true -> mutate(state, {:remove, child_ids}, :ok)
    end
  end

  # `:transient` is durable-compatible: a normal exit keeps the declared
  # entry, so the reconcile restarts the child at round cadence — the list
  # stays authoritative. Only `:temporary` — never restarted, spec removed on
  # exit — contradicts declaring the child durable.
  defp restartable?(%{restart: restart}), do: restart in [:permanent, :transient]
  defp restartable?(%{}), do: true

  # --- leader -----------------------------------------------------------------

  @doc """
  Starts elector participation. Elector is node-global; the strategy module is
  set only when unset so another user of it keeps its configuration.

  Elector comes along as a process_hub dependency, but it is left out when you
  build a release. Add `{:elector, "~> 0.3.4"}` to your own dependencies so the
  release includes it. Without it there is no election and `leader/1` picks the
  first node by name instead, which is fine on a single node and still gives
  one leader across a cluster.
  """
  @spec ensure_election() :: :ok
  def ensure_election do
    case Application.ensure_started(:elector) do
      :ok ->
        if Application.get_env(:elector, :strategy_module) === nil do
          Application.put_env(:elector, :strategy_module, :elector_ut_high_strategy)
        end

        Elector.elect()
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Resolves the hub's current leader: the elector leader when it is a hub member,
  otherwise the lexicographically lowest hub member — deterministic within a
  connected component, so exactly one node accepts writes.
  """
  @spec leader(Hub.t()) :: node()
  def leader(hub) do
    hub_nodes = Cluster.nodes(hub.storage.misc, [:include_local])

    case elector_leader() do
      {:ok, leader} ->
        if Enum.member?(hub_nodes, leader), do: leader, else: Enum.min(hub_nodes)

      :error ->
        Enum.min(hub_nodes)
    end
  end

  # `Elector.get_leader/0` exits with :noproc when elector is down (teardown).
  defp elector_leader do
    try do
      case Elector.get_leader() do
        {:ok, leader} -> {:ok, leader}
        _ -> re_elect()
      end
    catch
      _, _ -> :error
    end
  end

  defp re_elect do
    case Elector.elect_sync() do
      {:ok, leader} -> {:ok, leader}
      _ -> :error
    end
  end

  # A remote leader is asked outside the coordinator (`ask_leader/2`);
  # `unreachable` is the precommit's answer when that leader cannot be reached.
  defp mutate(state, mutation, unreachable \\ {:error, :no_leader}) do
    case leader(state.hub) do
      leader when leader === node() -> apply_mutation(state, mutation)
      leader -> {:remote, leader, mutation, unreachable}
    end
  end

  @doc """
  Asks the leader of a `{:remote, ...}` precommit to apply its mutation and
  answers as the precommit: `:ok` once the leader has written it, or an error.
  Runs outside the coordinator, so no coordinator waits on a leader.
  """
  @spec ask_leader(ProcessHub.hub_id(), precommit()) :: :ok | {:error, term()}
  def ask_leader(hub_id, {:remote, leader, mutation, unreachable}) do
    GenServer.call({hub_id, leader}, {:declared_mutate, mutation}, @mutate_timeout)
  catch
    :exit, _ -> unreachable
  end

  @doc """
  Applies a mutation as the leader; MUST run inside the coordinator process so
  writes serialize. A mutation that changes nothing does not bump the version.

  A mutation that changes the list answers `{:pending, manifest}`: the new
  manifest is the batch's working copy, not yet written. The coordinator parks
  the command behind `defer/4` and runs it from `flush/1`, after the one write
  and sync that persists the whole batch — so N commands cost one manifest
  write, not N rewrites of a list that grows with every child.
  """
  @spec apply_mutation(State.t(), mutation()) :: :ok | {:pending, manifest()} | {:error, term()}
  def apply_mutation(%State{hub: hub} = state, mutation) do
    cond do
      not hub.recovery_config.enabled? ->
        {:error, :durable_requires_auto_recovery}

      parked?(hub) ->
        {:error, :declared_list_parked}

      true ->
        manifest = working_manifest(state) || new_manifest(0, %{})
        entries = mutate_entries(manifest.entries, mutation)

        if entries === manifest.entries do
          :ok
        else
          {:pending, new_manifest(manifest.version + 1, entries)}
        end
    end
  end

  defp mutate_entries(entries, {:add, child_specs}) do
    Enum.reduce(child_specs, entries, &Map.put(&2, &1.id, &1))
  end

  defp mutate_entries(entries, {:remove, child_ids}) do
    Map.drop(entries, child_ids)
  end

  # The batch's working manifest while one is open, else the persisted one.
  defp working_manifest(%State{declared_unsynced: nil, hub: hub}), do: manifest(hub)
  defp working_manifest(%State{declared_unsynced: manifest}), do: manifest

  @doc """
  Parks `continuation` behind the write of `manifest`, the batch's working
  copy. One `:flush_declared` is queued per batch (`Batch.add/3`) and lands
  behind every request already in the coordinator's mailbox, so concurrent
  durable commands share one write and sync — and none of them runs before
  the write that covers its entry. MUST run inside the coordinator process.
  """
  @spec defer(State.t(), manifest(), GenServer.from(), command()) :: State.t()
  def defer(%State{} = state, manifest, from, continuation) do
    %{
      state
      | declared_unsynced: manifest,
        declared_batch: Batch.add(state.declared_batch, :flush_declared, {from, continuation})
    }
  end

  @doc """
  Writes and syncs the batch's working manifest once, publishes it (peers
  adopt the newest version, so the batch's intermediate versions need no
  broadcast of their own), then runs every parked command in arrival order
  and replies to its caller. A write that fails answers every parked caller
  with the error and runs none of them — no child starts on an intent that
  did not persist. MUST run inside the coordinator process; the coordinator
  flushes before it considers a peer's copy, so an adoption never overwrites
  a batch in flight.
  """
  @spec flush(State.t()) :: State.t()
  def flush(%State{declared_unsynced: nil} = state), do: state

  def flush(%State{declared_unsynced: manifest, hub: hub} = state) do
    {pending, batch} = Batch.take(state.declared_batch)
    state = %{state | declared_unsynced: nil, declared_batch: batch}

    result =
      case Store.write(hub, manifest) do
        :ok ->
          broadcast(hub, manifest)
          Store.ship(hub, manifest)
          :ok

        {:error, reason} ->
          {:error, {:declared_list_write_failed, reason}}
      end

    Enum.reduce(pending, state, fn {from, command}, state ->
      resume(state, result, from, command)
    end)
  end

  @doc """
  Answers a command held back by its precommit: runs it and replies with its
  answer once the precommit is `:ok`, or replies with the precommit's error
  without running it. MUST run inside the coordinator process.
  """
  @spec resume(State.t(), :ok | {:error, term()}, GenServer.from(), command()) :: State.t()
  def resume(state, :ok, from, command) do
    {:reply, reply, state} = command.(state)
    GenServer.reply(from, reply)
    state
  end

  def resume(state, {:error, _} = error, from, _command) do
    GenServer.reply(from, error)
    state
  end

  # --- adoption ---------------------------------------------------------------

  @doc """
  Adopts an incoming manifest when it wins: a higher version wholesale, a tie
  with differing content by lowest mutating node (WARN + tiebreak hook). MUST
  run inside the coordinator process.
  """
  @spec adopt(Hub.t(), manifest()) :: :ok
  def adopt(hub, %{format: format} = incoming) when format <= @format do
    local = manifest(hub)

    cond do
      local === nil or incoming.version > local.version ->
        adopt_commit(hub, incoming)

      incoming.version === local.version and incoming.entries !== local.entries ->
        resolve_tie(hub, local, incoming)

      true ->
        :ok
    end
  end

  def adopt(hub, %{format: format}) do
    LoggerService.warning(
      "Ignoring declared list with unsupported format @format",
      %{"format" => Integer.to_string(format)},
      prefix: "DeclaredChildren",
      hub_id: hub.hub_id
    )

    :ok
  end

  defp adopt_commit(hub, manifest) do
    case Store.write(hub, manifest) do
      :ok ->
        Store.clear_parked(hub)
        :ok

      {:error, reason} ->
        LoggerService.warning(
          "Could not persist adopted declared list v@version: @reason",
          %{"version" => Integer.to_string(manifest.version), "reason" => inspect(reason)},
          prefix: "DeclaredChildren",
          hub_id: hub.hub_id
        )

        :ok
    end
  end

  defp resolve_tie(hub, local, incoming) do
    {winner, loser} =
      if incoming.mutated_by < local.mutated_by, do: {incoming, local}, else: {local, incoming}

    LoggerService.warning(
      "Declared list version tie at v@version with differing content; keeping the copy " <>
        "mutated by @kept over @discarded",
      %{
        "version" => Integer.to_string(local.version),
        "kept" => Atom.to_string(winner.mutated_by),
        "discarded" => Atom.to_string(loser.mutated_by)
      },
      prefix: "DeclaredChildren",
      hub_id: hub.hub_id
    )

    HookManager.dispatch_hook(hub.storage.hook, Hook.declared_tiebreak(), %{
      hub_id: hub.hub_id,
      version: local.version,
      kept_mutated_by: winner.mutated_by,
      discarded_mutated_by: loser.mutated_by
    })

    if winner === incoming, do: adopt_commit(hub, incoming), else: :ok
  end

  @doc """
  Announces the local list version to hub peers; a lower-version peer pulls
  the full list. A no-op while the gate is off, parked, or nothing declared.
  """
  @spec announce_version(Hub.t()) :: :ok
  def announce_version(%Hub{recovery_config: %{enabled?: false}}), do: :ok

  def announce_version(hub) do
    with false <- parked?(hub),
         %{version: version} when version > 0 <- manifest(hub) do
      Dispatcher.dispatch_event(
        hub.procs.event_queue,
        @event_declared_version,
        {node(), version},
        %{members: :external}
      )

      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  Handles a peer's version announce: when the local copy is older, fetches the
  peer's manifest in a supervised task and casts it back for adoption.
  """
  @spec maybe_pull(Hub.t(), node(), non_neg_integer()) :: :ok
  def maybe_pull(hub, from_node, version) do
    local_version =
      case manifest(hub) do
        nil -> 0
        %{version: v} -> v
      end

    if hub.recovery_config.enabled? and version > local_version do
      hub_id = hub.hub_id
      event_queue = hub.procs.event_queue

      Task.Supervisor.start_child(hub.procs.task_sup, fn ->
        case :erpc.call(from_node, __MODULE__, :snapshot, [hub_id], @mutate_timeout) do
          %{} = manifest ->
            Dispatcher.dispatch_event(event_queue, @event_declared_adopt, manifest, %{
              members: :local
            })

          _ ->
            :ok
        end
      end)
    end

    :ok
  end

  # --- boot -------------------------------------------------------------------

  @doc "Resolves the list on coordinator boot; see `ProcessHub.Service.DeclaredChildren.Boot`."
  @spec boot(Hub.t()) :: {:ok, :ready | :parked | {:remote_error, term()}} | {:error, term()}
  defdelegate boot(hub), to: Boot, as: :run

  @doc "Fetches the remote copy; see `ProcessHub.Service.DeclaredChildren.Boot`."
  @spec remote_fetch(Hub.t()) :: Boot.fetched()
  defdelegate remote_fetch(hub), to: Boot

  @doc "Applies a re-fetched remote copy as boot would; MUST run inside the coordinator."
  @spec remote_recompare(Hub.t(), Boot.fetched()) :: :ok | {:error, term()}
  defdelegate remote_recompare(hub, fetched), to: Boot

  # --- operator ---------------------------------------------------------------

  @doc """
  Operator call: clears the hub's declared list. Destructive — nothing remains
  declared and the reconcile stops running declared children. Written above
  every known version so it wins adoption everywhere; lifts the park state.
  """
  @spec clear(ProcessHub.hub_id()) :: :ok | {:error, term()}
  def clear(hub_id) do
    GenServer.call(hub_id, :declared_clear)
  end

  @doc false
  @spec handle_clear(Hub.t()) :: :ok | {:error, term()}
  def handle_clear(hub) do
    local_version =
      case manifest(hub) do
        nil -> 0
        %{version: version} -> version
      end

    remote_version =
      case Boot.remote_fetch(hub) do
        {:ok, %{version: version}} -> version
        _ -> 0
      end

    manifest = new_manifest(max(local_version, remote_version) + 1, %{})

    case Store.write(hub, manifest) do
      :ok ->
        Store.clear_parked(hub)
        Store.ship(hub, manifest)
        broadcast(hub, manifest)

        LoggerService.warning(
          "Declared list cleared by operator call at v@version",
          %{"version" => Integer.to_string(manifest.version)},
          prefix: "DeclaredChildren",
          hub_id: hub.hub_id
        )

        :ok

      {:error, reason} ->
        {:error, {:declared_list_write_failed, reason}}
    end
  end

  # --- storage ----------------------------------------------------------------

  @doc "Opens the list's durable store for the initializer; see `Store.open/2`."
  @spec open_storage(ProcessHub.hub_id(), term()) :: %{
          declared_backend: {module(), term()},
          declared_path: String.t()
        }
  defdelegate open_storage(hub_id, registry_backend), to: Store, as: :open

  defp broadcast(hub, manifest) do
    Dispatcher.dispatch_event(hub.procs.event_queue, @event_declared_adopt, manifest, %{
      members: :external
    })
  end
end
