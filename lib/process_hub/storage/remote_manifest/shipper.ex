defmodule ProcessHub.Storage.RemoteManifest.Shipper do
  @moduledoc """
  Ships declared-list versions to the configured remote manifest adapter:
  asynchronously, retried with exponential backoff, coalescing superseded
  versions so only the newest one is ever in flight. Failures emit the
  `manifest_ship_failed` hook and never affect the originating command.

  Started per hub only when the declared-children gate is on and a remote
  manifest is configured.
  """

  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Service.LoggerService
  alias ProcessHub.Storage.RemoteManifest

  use GenServer

  @backoff_base_ms 1_000
  @backoff_max_ms 30_000

  @doc false
  # The hub's shipper child, or none: present only when the declared-children
  # gate is on and a remote manifest is configured. Supervised before the
  # coordinator so a boot-time version comparison can already ship.
  @spec child_specs(ProcessHub.hub_id(), map(), term(), :ets.tid()) :: [
          Supervisor.child_spec() | tuple()
        ]
  def child_specs(
        hub_id,
        %{enabled?: true, remote_manifest: {_mod, _opts} = remote},
        pname,
        hook_storage
      ) do
    [{__MODULE__, {hub_id, pname, remote, hook_storage}}]
  end

  def child_specs(_hub_id, _recovery_config, _pname, _hook_storage), do: []

  def start_link({hub_id, pname, {adapter, adapter_opts}, hook_storage}) do
    GenServer.start_link(
      __MODULE__,
      %{
        hub_id: hub_id,
        adapter: adapter,
        adapter_opts: adapter_opts,
        hook_storage: hook_storage,
        pending: nil,
        shipped: 0,
        attempt: 0
      },
      name: pname
    )
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:ship, manifest}, state) do
    if manifest.version > max(state.shipped, pending_version(state)) do
      send(self(), :attempt)
      {:noreply, %{state | pending: manifest, attempt: 0}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:attempt, %{pending: nil} = state), do: {:noreply, state}

  def handle_info(:attempt, %{pending: manifest} = state) do
    blob = RemoteManifest.encode(manifest)

    case safe_store(state, manifest.version, blob) do
      :ok ->
        {:noreply, %{state | pending: nil, shipped: manifest.version, attempt: 0}}

      {:error, reason} ->
        attempt = state.attempt + 1
        report_failure(state, manifest.version, reason, attempt)
        Process.send_after(self(), :attempt, backoff(attempt))
        {:noreply, %{state | attempt: attempt}}
    end
  end

  defp pending_version(%{pending: nil}), do: 0
  defp pending_version(%{pending: %{version: version}}), do: version

  defp safe_store(state, version, blob) do
    state.adapter.store(state.hub_id, version, blob, state.adapter_opts)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp report_failure(state, version, reason, attempt) do
    LoggerService.warning(
      "Remote manifest ship of v@version failed (attempt @attempt): @reason",
      %{
        "version" => Integer.to_string(version),
        "attempt" => Integer.to_string(attempt),
        "reason" => inspect(reason)
      },
      prefix: "RemoteManifest",
      hub_id: state.hub_id
    )

    HookManager.dispatch_hook(state.hook_storage, Hook.manifest_ship_failed(), %{
      hub_id: state.hub_id,
      version: version,
      error: reason,
      attempt: attempt
    })
  end

  defp backoff(attempt) do
    min(@backoff_base_ms * Integer.pow(2, attempt - 1), @backoff_max_ms)
  end
end
