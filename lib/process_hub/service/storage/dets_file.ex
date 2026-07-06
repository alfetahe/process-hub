defmodule ProcessHub.Service.Storage.DetsFile do
  @moduledoc """
  On-disk DETS file management shared by the DETS-file storage backends
  (`ProcessHub.Service.Storage.Dets` and `ProcessHub.Service.Storage.DurableEts`).

  Covers path resolution and corruption rotation. It is specific to persisting
  through a DETS file; in-memory or remote backends do not use it.
  """

  require Logger

  @doc "Resolves the on-disk path for `hub_id` (`:path` option, else `priv/process_hub/<hub_id>/registry.dets`)."
  @spec resolve_path(atom(), keyword()) :: String.t()
  def resolve_path(hub_id, opts) do
    case Keyword.get(opts, :path) do
      nil -> default_path(hub_id)
      path when is_binary(path) -> path
      path when is_list(path) -> List.to_string(path)
    end
  end

  @doc "Rotates a corrupt DETS file aside, logs at ERROR, and reopens a fresh file."
  @spec rotate_and_reopen(atom(), String.t(), term()) ::
          {{:ok, atom()} | {:error, term()}, boolean()}
  def rotate_and_reopen(hub_id, path, reason) do
    rotated = "#{path}.corrupt-#{System.monotonic_time()}"
    _ = File.rename(path, rotated)

    Logger.error(
      "ProcessHub registry backend corrupt for #{inspect(hub_id)}: " <>
        "rotated #{path} to #{rotated} (#{inspect(reason)}); reopening empty."
    )

    case :dets.open_file(hub_id, file: to_charlist(path), repair: true, type: :set) do
      {:ok, table} -> {{:ok, table}, true}
      {:error, _} = err -> {err, false}
    end
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
