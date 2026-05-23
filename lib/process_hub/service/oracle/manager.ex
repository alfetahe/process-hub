defmodule ProcessHub.Service.Oracle.Manager do
  @moduledoc false
  # Per-node manager for the leader-hosted oracle. Auto-started by
  # `ProcessHub.Service.Leadership.start/0`. It subscribes to leadership changes
  # and:
  #
  #   * keeps exactly one `ProcessHub.Service.Oracle` running on the leader node
  #     (starts it when this node becomes leader, stops it when it loses
  #     leadership), and
  #   * records this node's directory announcements and re-announces them to the
  #     (possibly new) oracle on every leadership change, so a failed-over oracle
  #     rebuilds its directory from re-announcement.

  use GenServer

  alias ProcessHub.Service.Leadership
  alias ProcessHub.Service.Oracle

  # Retry delay while a stale oracle on the previous leader is still shutting down.
  @ensure_retry_ms 150

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec whereis() :: pid() | nil
  def whereis(), do: Process.whereis(__MODULE__)

  @doc "Announces `hub_id` to the directory and records it for re-announcement."
  @spec announce(ProcessHub.hub_id(), map()) :: :ok
  def announce(hub_id, metadata \\ %{}), do: GenServer.call(__MODULE__, {:announce, hub_id, metadata})

  @doc "Withdraws `hub_id` from the directory and stops re-announcing it."
  @spec withdraw(ProcessHub.hub_id()) :: :ok
  def withdraw(hub_id), do: GenServer.call(__MODULE__, {:withdraw, hub_id})

  ##############################################################################
  ### Callbacks
  ##############################################################################

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    # The initial snapshot drives the first lifecycle decision.
    Leadership.subscribe(self())
    {:ok, %{announcements: %{}, oracle_pid: nil, am_i_leader: false}}
  end

  @impl true
  def handle_call({:announce, hub_id, metadata}, _from, state) do
    state = put_in(state.announcements[hub_id], metadata)
    Oracle.announce(hub_id, node(), metadata)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:withdraw, hub_id}, _from, state) do
    state = %{state | announcements: Map.delete(state.announcements, hub_id)}
    Oracle.withdraw(hub_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:processhub_leadership, %{am_i_leader: am_i_leader}}, state) do
    state = %{state | am_i_leader: am_i_leader}
    state = manage_oracle(state)
    reannounce(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:ensure_oracle, %{am_i_leader: true} = state) do
    {:noreply, manage_oracle(state)}
  end

  @impl true
  def handle_info(:ensure_oracle, state), do: {:noreply, state}

  @impl true
  def handle_info(:reannounce, state) do
    reannounce(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %{oracle_pid: pid} = state) do
    # Our oracle died; if we are still leader, bring a fresh one up.
    state = %{state | oracle_pid: nil}
    {:noreply, manage_oracle(state)}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_local_oracle(state)
    :ok
  end

  ##############################################################################
  ### Private functions
  ##############################################################################

  defp manage_oracle(%{am_i_leader: true} = state), do: ensure_oracle(state)

  defp manage_oracle(%{am_i_leader: false} = state) do
    stop_local_oracle(state)
    %{state | oracle_pid: nil}
  end

  # Ensure the single global oracle is hosted on this (leader) node.
  defp ensure_oracle(state) do
    case Oracle.start_link() do
      {:ok, pid} ->
        broadcast_reannounce()
        %{state | oracle_pid: pid}

      {:error, {:already_started, pid}} ->
        if node(pid) === node() do
          %{state | oracle_pid: pid}
        else
          # A stale oracle on the previous leader is still up — stop it and
          # retry shortly so this node takes over the global registration.
          stop_pid(pid)
          Process.send_after(self(), :ensure_oracle, @ensure_retry_ms)
          state
        end
    end
  end

  defp stop_local_oracle(%{oracle_pid: pid}) when is_pid(pid) do
    if node(pid) === node(), do: stop_pid(pid)
  end

  defp stop_local_oracle(_state), do: :ok

  defp stop_pid(pid) do
    try do
      GenServer.stop(pid)
    catch
      _kind, _reason -> :ok
    end
  end

  defp reannounce(%{announcements: announcements}) do
    Enum.each(announcements, fn {hub_id, metadata} ->
      Oracle.announce(hub_id, node(), metadata)
    end)
  end

  defp broadcast_reannounce() do
    Enum.each([node() | Node.list()], fn n -> send({__MODULE__, n}, :reannounce) end)
  end
end
