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
  alias ProcessHub.Service.Storage
  alias ProcessHub.Hub

  use Event

  @format 1
  @mutate_timeout 5_000

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
    case cached(hub_id) do
      nil -> %{version: 0, children: []}
      %{version: version, entries: entries} -> %{version: version, children: Map.values(entries)}
    end
  end

  @doc "Returns the full cached manifest, or `nil` when none exists."
  @spec snapshot(ProcessHub.hub_id()) :: manifest() | nil
  def snapshot(hub_id), do: cached(hub_id)

  @doc "Returns whether the hub's reconcile is parked over a lost declared list."
  @spec parked?(Hub.t()) :: boolean()
  def parked?(%Hub{storage: %{misc: misc}}) do
    Storage.get(misc, StorageKey.dclp()) === true
  end

  @doc "Returns the cached manifest read directly from the hub's misc storage."
  @spec manifest(Hub.t()) :: manifest() | nil
  def manifest(%Hub{storage: %{misc: misc}}), do: Storage.get(misc, StorageKey.dcl())

  defp cached(hub_id) when is_atom(hub_id) do
    case Process.whereis(hub_id) do
      nil ->
        nil

      _pid ->
        try do
          manifest(GenServer.call(hub_id, :get_state))
        catch
          :exit, _ -> nil
        end
    end
  end

  # --- command precommit ------------------------------------------------------

  @doc """
  Commits the list additions a `durable: true` start requires, before any
  process starts. Refuses when the gate is off, the list is parked, a spec is
  not `:permanent`, or no leader is reachable. `:ok` for non-durable starts.
  """
  @spec precommit_start(Hub.t(), [ProcessHub.child_spec()], keyword()) :: :ok | {:error, term()}
  def precommit_start(hub, child_specs, opts) do
    cond do
      not Keyword.get(opts, :durable, false) -> :ok
      not hub.recovery_config.enabled? -> {:error, :durable_requires_auto_recovery}
      parked?(hub) -> {:error, :declared_list_parked}
      not Enum.all?(child_specs, &permanent?/1) -> {:error, :durable_requires_permanent}
      true -> mutate(hub, {:add, child_specs})
    end
  end

  @doc """
  Commits the list removals a stop requires, before any child terminates. The
  leader's copy is authoritative; with no leader reachable the stop is refused
  only when the local copy shows a declared child among `child_ids`.
  """
  @spec precommit_stop(Hub.t(), [ProcessHub.child_id()]) :: :ok | {:error, term()}
  def precommit_stop(%Hub{recovery_config: %{enabled?: false}}, _child_ids), do: :ok

  def precommit_stop(hub, child_ids) do
    locally_declared? =
      case manifest(hub) do
        nil -> false
        %{entries: entries} -> Enum.any?(child_ids, &Map.has_key?(entries, &1))
      end

    cond do
      parked?(hub) and locally_declared? -> {:error, :declared_list_parked}
      parked?(hub) -> :ok
      true -> mutate_stop(hub, child_ids, locally_declared?)
    end
  end

  defp mutate_stop(hub, child_ids, locally_declared?) do
    case mutate(hub, {:remove, child_ids}) do
      :ok -> :ok
      {:error, :no_leader} when not locally_declared? -> :ok
      {:error, _} = error -> error
    end
  end

  defp permanent?(%{restart: restart}), do: restart === :permanent
  defp permanent?(%{}), do: true

  # --- leader -----------------------------------------------------------------

  @doc """
  Starts elector participation. Elector is node-global; the strategy module is
  set only when unset so another user of it keeps its configuration.
  """
  @spec ensure_election() :: :ok
  def ensure_election do
    Application.ensure_started(:elector)

    if Application.get_env(:elector, :strategy_module) === nil do
      Application.put_env(:elector, :strategy_module, :elector_ut_high_strategy)
    end

    Elector.elect()
    :ok
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

  defp mutate(hub, mutation) do
    case leader(hub) do
      leader when leader === node() ->
        apply_mutation(hub, mutation)

      leader ->
        try do
          :erpc.call(
            leader,
            GenServer,
            :call,
            [hub.hub_id, {:declared_mutate, mutation}, @mutate_timeout],
            @mutate_timeout + 500
          )
        catch
          _, _ -> {:error, :no_leader}
        end
    end
  end

  @doc """
  Applies a mutation as the leader; MUST run inside the coordinator process so
  writes serialize. A mutation that changes nothing does not bump the version.
  """
  @spec apply_mutation(Hub.t(), {:add, [ProcessHub.child_spec()]} | {:remove, [term()]}) ::
          :ok | {:error, term()}
  def apply_mutation(hub, mutation) do
    cond do
      not hub.recovery_config.enabled? ->
        {:error, :durable_requires_auto_recovery}

      parked?(hub) ->
        {:error, :declared_list_parked}

      true ->
        manifest = manifest(hub) || new_manifest(0, %{})
        entries = mutate_entries(manifest.entries, mutation)

        if entries === manifest.entries do
          :ok
        else
          commit(hub, new_manifest(manifest.version + 1, entries))
        end
    end
  end

  defp mutate_entries(entries, {:add, child_specs}) do
    Enum.reduce(child_specs, entries, &Map.put(&2, &1.id, &1))
  end

  defp mutate_entries(entries, {:remove, child_ids}) do
    Map.drop(entries, child_ids)
  end

  defp commit(hub, manifest) do
    case Store.write(hub, manifest) do
      :ok ->
        broadcast(hub, manifest)
        Store.ship(hub, manifest)
        :ok

      {:error, reason} ->
        {:error, {:declared_list_write_failed, reason}}
    end
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

  @doc "Re-runs the boot-time remote comparison; MUST run inside the coordinator."
  @spec remote_recompare(Hub.t()) :: :ok | {:error, term()}
  defdelegate remote_recompare(hub), to: Boot

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
