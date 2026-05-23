defmodule ProcessHub.Service.Leadership do
  @moduledoc """
  Opt-in, cluster-wide leadership backed by the `:elector` library.

  Leadership elects a single leader **node** per BEAM cluster. It is **opt-in**:
  starting it also starts Erlang `:global` (a real cost), so `ProcessHub` never
  starts `:elector` by default. Leadership is started only when:

    * the user explicitly calls `start/0` (`ProcessHub.start_leadership/0`), or
    * a distribution strategy that requires it (`CentralizedLoadBalancer`) starts it.

  The query functions (`leader/0`, `is_leader?/0`) never start `:elector`; they
  read the locally-registered `:elector_state` process. "Leadership started" is
  therefore true whether `:elector` was started by `start/0` or by the strategy.

  All leadership logic lives here; `ProcessHub` exposes only thin delegators.
  """

  alias :elector, as: Elector
  alias ProcessHub.Service.Leadership.Watcher
  alias ProcessHub.Service.Oracle

  # The elector state process is locally registered under this name; its
  # presence is the single source of truth for "leadership is started".
  @elector_state :elector_state

  # Bounded retry around the asynchronous election commission: elector's
  # `elect/0` is async and the global commission may not be up the instant the
  # application starts, so we re-trigger until a leader is set or we give up.
  @elect_attempts 50
  @elect_delay_ms 100

  # Time for the async candidate-status broadcast to reach peer caches before we
  # trigger the step-down re-election that must exclude this node.
  @stepdown_settle_ms 300

  @typedoc "The current leader node, or `:none` when no leader is elected yet."
  @type leader() :: node() | :none

  @doc """
  Starts the local `:elector` instance (and therefore `:global`), waits for a
  leader to be elected, and starts the leadership watcher.

  Idempotent: calling it when leadership is already started just ensures a leader
  is elected. Returns `:ok`, or `{:error, term()}` if `:elector` fails to start.
  """
  @spec start() :: :ok | {:error, term()}
  def start() do
    # Undo any prior graceful step-down that marked this node ineligible.
    Application.put_env(:elector, :candidate_node, true)

    case ensure_started() do
      :ok ->
        refresh_candidacy()
        install_election_hook()
        elect_with_retry()
        ensure_watcher_started()
        # Pick up the leader if the watcher pre-existed (subscribed before start).
        Watcher.recheck()
        # The oracle manager hosts the leader-only oracle and keeps it failed
        # over; it subscribes to the watcher, so start it after the watcher.
        ensure_manager_started()
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Stops leadership on the local node. No-op when leadership is not started.

  When the local node is the current leader of a multi-node cluster, it steps
  down gracefully first — it makes itself ineligible and prompts an immediate
  re-election among the remaining nodes, so a successor is chosen without waiting
  for a `nodedown` timeout.
  """
  @spec stop() :: :ok
  def stop() do
    if started?() do
      step_down()
      # Stop the manager first so it tears down the leader-hosted oracle.
      stop_manager()
      stop_watcher()
      Application.stop(:elector)
    end

    :ok
  end

  @doc """
  Subscribes `pid` (default `self()`) to leadership-change notifications.

  The subscriber immediately receives the current snapshot and then a message on
  each subsequent change:

      {:processhub_leadership, %{leader: node() | :none, previous: node() | :none | nil, am_i_leader: boolean()}}

  Subscriptions are cleaned up automatically when the subscriber dies.
  """
  @spec subscribe(pid()) :: :ok
  def subscribe(pid \\ self()) do
    ensure_watcher_started()
    Watcher.subscribe(pid)
  end

  @doc "Unsubscribes `pid` (default `self()`) from leadership-change notifications."
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid \\ self()) do
    case Watcher.whereis() do
      nil -> :ok
      _pid -> Watcher.unsubscribe(pid)
    end
  end

  @doc """
  Evaluates the zero-arity `fun` only if the local node is the leader, returning
  its result. Otherwise returns `{:error, :not_leader}` without evaluating it.
  """
  @spec on_leader((-> result)) :: result | {:error, :not_leader} when result: var
  def on_leader(fun) when is_function(fun, 0) do
    if is_leader?() do
      fun.()
    else
      {:error, :not_leader}
    end
  end

  @doc """
  Returns whether leadership has been started on the local node.

  Detected by the locally-registered `:elector_state` process, so it is true
  whether `:elector` was started via `start/0` or by `CentralizedLoadBalancer`.
  """
  @spec started?() :: boolean()
  def started?() do
    Process.whereis(@elector_state) != nil
  end

  @doc """
  Returns the current leader node.

    * `{:ok, node()}` — the elected leader.
    * `{:ok, :none}` — leadership is started but no leader is elected yet.
    * `{:error, :leadership_not_started}` — leadership has not been started.

  Never starts `:elector` as a side effect.
  """
  @spec leader() :: {:ok, leader()} | {:error, :leadership_not_started}
  def leader() do
    if started?() do
      {:ok, current_leader()}
    else
      {:error, :leadership_not_started}
    end
  end

  @doc """
  Returns whether the local node is the leader. `false` when leadership is not
  started. Never starts `:elector` as a side effect.
  """
  @spec is_leader?() :: boolean()
  def is_leader?() do
    started?() and current_leader() === node()
  end

  ##############################################################################
  ### elector helpers
  ##############################################################################

  defp ensure_started() do
    case Application.ensure_started(:elector) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  # Normalises elector's leader response to `node() | :none`. elector returns
  # `{:ok, :undefined}` (an atom, so it takes the `{:ok, _}` branch) before the
  # first election completes, and `{:error, :leader_node_not_set}` defensively.
  defp current_leader() do
    case Elector.get_leader() do
      {:ok, :undefined} -> :none
      {:ok, leader_node} when is_atom(leader_node) -> leader_node
      {:error, :leader_node_not_set} -> :none
    end
  end

  defp elect_with_retry(attempts \\ @elect_attempts)

  defp elect_with_retry(0), do: current_leader()

  defp elect_with_retry(attempts) do
    case current_leader() do
      :none ->
        Elector.elect()
        Process.sleep(@elect_delay_ms)
        elect_with_retry(attempts - 1)

      leader_node ->
        leader_node
    end
  end

  # Installs the post-election hook that, after every election, pings each node's
  # watcher to re-check the leader. Set directly (not appended) so it stays
  # exactly-once across repeated `start/0` calls. Runs on the commission node
  # only (default `hooks_execution: :local`), which then fans out to all watchers.
  defp install_election_hook() do
    Application.put_env(:elector, :post_election_hooks, [{Watcher, :broadcast_recheck, []}])
    :ok
  end

  # Pushes the local `candidate_node` config into the running candidate process
  # and broadcasts it to peer candidate caches.
  defp refresh_candidacy() do
    try do
      :gen_server.call(:elector_candidate, :update_state)
    catch
      :exit, _ -> :ok
    end

    if Process.whereis(:elector_candidate_cache) do
      :elector_candidate_cache.refresh_local_status()
    end

    :ok
  end

  # Graceful step-down: only meaningful when this node is the leader of a
  # multi-node cluster. Make ourselves ineligible, let the status propagate, then
  # trigger a synchronous re-election that picks a successor among the rest.
  defp step_down() do
    if is_leader?() and Node.list() !== [] do
      Application.put_env(:elector, :candidate_node, false)
      refresh_candidacy()
      Process.sleep(@stepdown_settle_ms)
      Elector.elect_sync()
    end

    :ok
  end

  # The watcher is a per-node singleton whose lifecycle follows leadership, not
  # the caller's — start it linked then unlink so it survives the caller.
  defp ensure_watcher_started() do
    case Watcher.whereis() do
      nil ->
        case Watcher.start_link() do
          {:ok, pid} ->
            :erlang.unlink(pid)
            :ok

          {:error, {:already_started, _pid}} ->
            :ok
        end

      _pid ->
        :ok
    end
  end

  defp stop_watcher() do
    case Watcher.whereis() do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  # The oracle manager is a per-node singleton; like the watcher, start it linked
  # then unlink so it follows leadership rather than the caller.
  defp ensure_manager_started() do
    case Oracle.Manager.whereis() do
      nil ->
        case Oracle.Manager.start_link() do
          {:ok, pid} ->
            :erlang.unlink(pid)
            :ok

          {:error, {:already_started, _pid}} ->
            :ok
        end

      _pid ->
        :ok
    end
  end

  defp stop_manager() do
    case Oracle.Manager.whereis() do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end
end
