defmodule ProcessHub.Service.Oracle do
  @moduledoc """
  Authoritative, leader-hosted cluster-coordination service.

  Exactly one oracle runs in the cluster, on the elected leader node, registered
  globally. It is the single source of truth for cluster coordination:

    * a **hub directory** (hubs announce; others discover),
    * **cluster info/stats** (leader, known hubs, basic counts), and
    * the **single serializer** that admits/de-duplicates cluster-singleton work
      (`coordinate/2`) — work that must happen at most once cluster-wide.

  The oracle is distinct from leadership: the *leader* is the node, the *oracle*
  is the service that runs there. Its lifecycle (start on the leader, fail over
  with leadership, rebuild from re-announcement) is driven by
  `ProcessHub.Service.Oracle.Manager`.

  Reads/writes are routed to the single global instance, so the oracle's view is
  internally consistent by construction (no contradicting writers).
  """

  use GenServer

  alias ProcessHub.Service.Leadership

  @global_name __MODULE__

  # Cap on cached coordination results (the dedup window). Reset past the cap so
  # the cache cannot grow without bound; evicting a key just lets a future
  # request for it be re-admitted.
  @max_work_entries 10_000

  @type hub_entry() :: %{hub_id: ProcessHub.hub_id(), node: node(), metadata: map()}

  ##############################################################################
  ### Lifecycle (managed by Oracle.Manager on the leader)
  ##############################################################################

  @doc false
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: {:global, @global_name})
  end

  @doc "Pid of the single global oracle, or `:undefined`."
  @spec whereis() :: pid() | :undefined
  def whereis(), do: :global.whereis_name(@global_name)

  ##############################################################################
  ### Client API (callable from any node)
  ##############################################################################

  @doc "Announces a hub to the directory (with its node and metadata)."
  @spec announce(ProcessHub.hub_id(), node(), map()) :: :ok | {:error, :no_oracle}
  def announce(hub_id, hub_node, metadata \\ %{}) do
    call({:announce, hub_id, hub_node, metadata})
  end

  @doc "Removes a hub from the directory."
  @spec withdraw(ProcessHub.hub_id()) :: :ok | {:error, :no_oracle}
  def withdraw(hub_id), do: call({:withdraw, hub_id})

  @doc "Lists the announced hubs."
  @spec list_hubs() :: [hub_entry()] | {:error, :no_oracle}
  def list_hubs(), do: call(:list_hubs)

  @doc "Returns cluster info: current leader, known hubs, and basic stats."
  @spec info() :: %{leader: node() | :none, hubs: [hub_entry()], stats: map()} | {:error, :no_oracle}
  def info(), do: call(:info)

  @doc """
  Admits cluster-singleton `work` under `key` at most once. The first request for
  a `key` runs `work` (a zero-arity fun or `{m, f, a}`) and caches its result;
  later requests for the same `key` observe the cached result and do not re-run.

  Returns `{:ok, result}` on first admission, `{:already_done, result}` otherwise.
  """
  @spec coordinate(term(), (-> term()) | {module(), atom(), list()}) ::
          {:ok, term()} | {:already_done, term()} | {:error, :no_oracle}
  def coordinate(key, work), do: call({:coordinate, key, work})

  defp call(msg) do
    case whereis() do
      :undefined -> {:error, :no_oracle}
      pid -> GenServer.call(pid, msg)
    end
  end

  ##############################################################################
  ### Callbacks
  ##############################################################################

  @impl true
  def init(_), do: {:ok, %{directory: %{}, work: %{}}}

  @impl true
  def handle_call({:announce, hub_id, hub_node, metadata}, _from, state) do
    directory = Map.put(state.directory, hub_id, %{node: hub_node, metadata: metadata})
    {:reply, :ok, %{state | directory: directory}}
  end

  @impl true
  def handle_call({:withdraw, hub_id}, _from, state) do
    {:reply, :ok, %{state | directory: Map.delete(state.directory, hub_id)}}
  end

  @impl true
  def handle_call(:list_hubs, _from, state) do
    {:reply, hubs(state.directory), state}
  end

  @impl true
  def handle_call(:info, _from, state) do
    leader =
      case Leadership.leader() do
        {:ok, l} -> l
        {:error, :leadership_not_started} -> :none
      end

    info = %{
      leader: leader,
      hubs: hubs(state.directory),
      stats: %{
        hub_count: map_size(state.directory),
        node_count: length([node() | Node.list()])
      }
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call({:coordinate, key, work}, _from, state) do
    case Map.get(state.work, key) do
      {:done, result} ->
        {:reply, {:already_done, result}, state}

      nil ->
        # The work runs in the oracle process; guard it so a failing/unresponsive
        # coordination task (e.g. a bad migration target) cannot crash this shared
        # singleton. Failures are not cached, so they can be retried.
        try do
          result = run_work(work)
          {:reply, {:ok, result}, %{state | work: remember_work(state.work, key, result)}}
        catch
          kind, reason -> {:reply, {:error, {kind, reason}}, state}
        end
    end
  end

  ##############################################################################
  ### Private functions
  ##############################################################################

  defp hubs(directory) do
    Enum.map(directory, fn {hub_id, info} -> Map.put(info, :hub_id, hub_id) end)
  end

  defp run_work(work) when is_function(work, 0), do: work.()
  defp run_work({m, f, a}), do: apply(m, f, a)

  defp remember_work(work, key, result) do
    work = if map_size(work) >= @max_work_entries, do: %{}, else: work
    Map.put(work, key, {:done, result})
  end
end
