defmodule ProcessHub.Service.Storage.DetsFile do
  @moduledoc """
  On-disk DETS file management shared by the DETS-file storage backends
  (`ProcessHub.Service.Storage.Dets` and `ProcessHub.Service.Storage.DurableEts`).

  Covers path resolution, corruption rotation, and the durable-medium read. It is
  specific to persisting through a DETS file; in-memory or remote backends do not
  use it.
  """

  alias ProcessHub.Service.Storage.Entry

  require Logger

  @doc "Syncs `table` unless the write asked for `sync: false` (a group commit syncs later)."
  @spec maybe_sync(atom(), keyword()) :: :ok | {:error, term()}
  def maybe_sync(table, write_opts) do
    if Keyword.get(write_opts, :sync, true), do: :dets.sync(table), else: :ok
  end

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

  @doc """
  Folds `table` into its non-expired `{key, value}` rows.

  This is the `read_durable/1` implementation shared by both DETS-file backends:
  it reads the file only, never the live in-memory view either backend keeps
  beside it. An unreadable file returns `{:error, reason}` — never an empty set,
  which callers would mistake for "everything was deliberately removed".
  """
  @spec read_durable(atom()) :: {:ok, [{term(), term()}]} | {:error, term()}
  def read_durable(table) do
    folded =
      :dets.foldl(
        fn entry, acc ->
          if Entry.expired?(entry), do: acc, else: [{elem(entry, 0), elem(entry, 1)} | acc]
        end,
        [],
        table
      )

    case folded do
      {:error, reason} -> {:error, reason}
      rows when is_list(rows) -> {:ok, rows}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
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
