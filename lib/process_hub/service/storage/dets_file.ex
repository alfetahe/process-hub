defmodule ProcessHub.Service.Storage.DetsFile do
  @moduledoc """
  On-disk DETS file management shared by the DETS-file storage backends
  (`ProcessHub.Service.Storage.Dets` and `ProcessHub.Service.Storage.DurableEts`).

  Covers path resolution, corruption rotation, and the registry telemetry these
  backends emit. It is specific to persisting through a DETS file; in-memory or
  remote backends do not use it.
  """

  @doc "Resolves the on-disk path for `hub_id` (`:path` option, else `priv/process_hub/<hub_id>/registry.dets`)."
  @spec resolve_path(atom(), keyword()) :: String.t()
  def resolve_path(hub_id, opts) do
    case Keyword.get(opts, :path) do
      nil -> default_path(hub_id)
      path when is_binary(path) -> path
      path when is_list(path) -> List.to_string(path)
    end
  end

  @doc "Rotates a corrupt DETS file aside, emits `:backend_corrupt`, and reopens a fresh file."
  @spec rotate_and_reopen(atom(), String.t(), term()) ::
          {{:ok, atom()} | {:error, term()}, boolean()}
  def rotate_and_reopen(hub_id, path, reason) do
    rotated = "#{path}.corrupt-#{System.monotonic_time()}"
    _ = File.rename(path, rotated)

    emit(:backend_corrupt, %{}, %{
      hub_id: hub_id,
      path: path,
      rotated_to: rotated,
      reason: reason
    })

    case :dets.open_file(hub_id, file: to_charlist(path), repair: true, type: :set) do
      {:ok, table} -> {{:ok, table}, true}
      {:error, _} = err -> {err, false}
    end
  end

  @doc "Emits `:backend_opened` telemetry for `backend` with the current row count."
  @spec emit_opened(atom(), module(), String.t(), boolean(), boolean()) :: :ok
  def emit_opened(hub_id, backend, path, repaired?, replayed?) do
    row_count =
      try do
        :dets.info(hub_id, :size) || 0
      rescue
        _ -> 0
      end

    emit(:backend_opened, %{row_count: row_count, elapsed_ms: 0}, %{
      hub_id: hub_id,
      backend: backend,
      path: path,
      repaired: repaired?,
      replayed: replayed?
    })
  end

  @doc "Emits a `[:process_hub, :registry, event]` telemetry event (best effort)."
  @spec emit(atom(), map(), map()) :: :ok
  def emit(event, measurements, metadata) do
    :telemetry.execute([:process_hub, :registry, event], measurements, metadata)
  rescue
    UndefinedFunctionError -> :ok
    ArgumentError -> :ok
  end

  defp default_path(hub_id) do
    base =
      case :code.priv_dir(:process_hub) do
        {:error, :bad_name} -> Path.join([File.cwd!(), "priv"])
        priv when is_list(priv) -> List.to_string(priv)
      end

    Path.join([base, "process_hub", Atom.to_string(hub_id), "registry.dets"])
  end
end
