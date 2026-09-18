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

  @doc """
  The on-disk path in `opts`, or `nil` when none was given.

  The single place backend options are read for a file location, so "was this
  backend told where to write?" is answered the same way everywhere.
  """
  @spec configured_path(keyword()) :: String.t() | nil
  def configured_path(opts) when is_list(opts) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) -> path
      path when is_list(path) -> List.to_string(path)
      _missing -> nil
    end
  end

  def configured_path(_opts), do: nil

  @doc """
  Returns the on-disk path the backend was configured with, or raises.

  There is no default: a library cannot know a location its host owns, and the
  one it used to pick sat in its own `priv`, where the host could not reach it.
  """
  @spec resolve_path(atom(), keyword()) :: String.t()
  def resolve_path(hub_id, opts) do
    configured_path(opts) ||
      raise ArgumentError,
            "a DETS-file storage backend for #{inspect(hub_id)} needs a :path option, " <>
              "for example registry_backend: {:dets, path: \"/var/lib/myapp/hub.dets\"}"
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
end
