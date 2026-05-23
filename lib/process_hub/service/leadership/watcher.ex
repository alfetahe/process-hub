defmodule ProcessHub.Service.Leadership.Watcher do
  @moduledoc false
  # Per-node leadership watcher. Detects leadership changes event-driven (no busy
  # polling) from two sources:
  #
  #   * `:net_kernel.monitor_nodes/1` — cluster-membership changes, and
  #   * an elector post-election hook (`broadcast_recheck/0`) that pings every
  #     node's watcher after each election (covers graceful step-down, where no
  #     `:nodedown` fires on peers).
  #
  # Both feed a short debounced re-check; on a real change it notifies
  # subscribers with `{:processhub_leadership, %{leader, previous, am_i_leader}}`
  # and emits `[:process_hub, :leadership, :changed]` telemetry.

  use GenServer

  alias ProcessHub.Service.Leadership

  @notification :processhub_leadership
  # Short debounce so a burst of triggers coalesces and the elector `set_leader`
  # broadcast has time to land before we read it. The post-election hook is the
  # authoritative trigger, so this stays small.
  @debounce_ms 200

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Pid of the local watcher, or nil."
  @spec whereis() :: pid() | nil
  def whereis(), do: Process.whereis(__MODULE__)

  @spec subscribe(pid()) :: :ok
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid), do: GenServer.call(__MODULE__, {:unsubscribe, pid})

  @doc "Triggers a (debounced) re-check on the local watcher, if running."
  @spec recheck() :: :ok
  def recheck() do
    case whereis() do
      nil -> :ok
      pid -> send(pid, :recheck) && :ok
    end
  end

  @doc """
  Runs on the election commission node via elector's post-election hook and pings
  every connected node's watcher to re-check. Safe to call where no watcher runs.
  """
  @spec broadcast_recheck() :: :ok
  def broadcast_recheck() do
    Enum.each([node() | Node.list()], fn n -> send({__MODULE__, n}, :recheck) end)
    :ok
  end

  ##############################################################################
  ### Callbacks
  ##############################################################################

  @impl true
  def init(_) do
    :net_kernel.monitor_nodes(true)
    leader = read_leader()

    # The watcher starting with a leader already elected is itself the initial
    # transition (nil -> leader) from its vantage point.
    if leader !== :none, do: emit_telemetry(nil, leader)

    {:ok, %{leader: leader, subscribers: %{}, timer: nil}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    state =
      if Map.has_key?(state.subscribers, pid) do
        state
      else
        ref = Process.monitor(pid)
        put_in(state.subscribers[pid], ref)
      end

    # Hand the subscriber the current snapshot so it learns the leader on join.
    send(pid, {@notification, snapshot(state.leader)})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    state =
      case Map.pop(state.subscribers, pid) do
        {nil, _subs} ->
          state

        {ref, subs} ->
          Process.demonitor(ref, [:flush])
          %{state | subscribers: subs}
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:recheck, state), do: {:noreply, schedule_recheck(state)}

  @impl true
  def handle_info({:nodeup, _node}, state), do: {:noreply, schedule_recheck(state)}

  @impl true
  def handle_info({:nodedown, _node}, state), do: {:noreply, schedule_recheck(state)}

  @impl true
  def handle_info(:do_recheck, state) do
    new_leader = read_leader()
    state = %{state | timer: nil}

    if new_leader !== state.leader do
      {:noreply, transition(state, new_leader)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscribers =
      case state.subscribers do
        %{^pid => ^ref} = subs -> Map.delete(subs, pid)
        subs -> subs
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  ##############################################################################
  ### Private functions
  ##############################################################################

  defp schedule_recheck(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :do_recheck, @debounce_ms)}
  end

  defp transition(state, new_leader) do
    previous = state.leader
    notify_subscribers(state.subscribers, new_leader, previous)
    emit_telemetry(previous, new_leader)
    %{state | leader: new_leader}
  end

  defp notify_subscribers(subscribers, leader, previous) do
    msg = {@notification, %{leader: leader, previous: previous, am_i_leader: leader === node()}}
    Enum.each(Map.keys(subscribers), fn pid -> send(pid, msg) end)
  end

  defp snapshot(leader) do
    %{leader: leader, previous: nil, am_i_leader: leader === node()}
  end

  defp read_leader() do
    case Leadership.leader() do
      {:ok, leader} -> leader
      {:error, :leadership_not_started} -> :none
    end
  end

  defp emit_telemetry(previous, leader) do
    if Code.ensure_loaded?(:telemetry) do
      :telemetry.execute(
        [:process_hub, :leadership, :changed],
        %{system_time: System.system_time()},
        %{leader: leader, previous: previous, am_i_leader: leader === node()}
      )
    end

    :ok
  end
end
