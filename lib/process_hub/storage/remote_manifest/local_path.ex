defmodule ProcessHub.Storage.RemoteManifest.LocalPath do
  @moduledoc """
  Filesystem adapter for `ProcessHub.Storage.RemoteManifest`. Dependency-free.

  > #### Experimental {: .warning}
  >
  > Part of the experimental declared-children feature; may change in future
  > releases.

  Stores one file per hub under the configured directory:
  `<path>/<hub_id>.manifest`, written atomically (temp file + rename).

  > #### The path must live off-cluster {: .warning}
  >
  > This adapter only protects against whole-cluster loss when `:path` points at
  > storage that outlives the cluster — an NFS mount, a persistent volume from
  > outside the cluster's disks. A path on a cluster node's own disk shares that
  > disk's fate.

  A plain filesystem offers no compare-and-swap, so the higher-version check is
  read-then-write: a concurrent writer can race it. The declared-list design
  tolerates that — only one leader ships at a time, and a superseded write is
  corrected by the next ship.

  ## Options

  - `:path` (required) — directory for the manifest files. Created if missing.
  """

  @behaviour ProcessHub.Storage.RemoteManifest

  @impl true
  def store(hub_id, version, blob, opts) do
    path = file_path(hub_id, opts)

    case read_version(path) do
      {:ok, stored_version} when stored_version > version ->
        :ok

      {:ok, stored_version} when stored_version === version ->
        :ok

      _ ->
        write_atomic(path, :erlang.term_to_binary({version, blob}))
    end
  end

  @impl true
  def fetch(hub_id, opts) do
    path = file_path(hub_id, opts)

    case File.read(path) do
      {:ok, content} -> decode(content)
      {:error, :enoent} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def info(opts) do
    %{adapter: :local_path, path: Keyword.get(opts, :path)}
  end

  @impl true
  def validate_config(opts) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) -> :ok
      _ -> {:error, {:local_path_requires_path, opts}}
    end
  end

  defp file_path(hub_id, opts) do
    Path.join(Keyword.fetch!(opts, :path), "#{hub_id}.manifest")
  end

  defp read_version(path) do
    with {:ok, content} <- File.read(path),
         {:ok, {version, _blob}} <- decode(content) do
      {:ok, version}
    else
      _ -> :error
    end
  end

  defp write_atomic(path, content) do
    File.mkdir_p!(Path.dirname(path))
    tmp = "#{path}.tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  defp decode(content) do
    case :erlang.binary_to_term(content) do
      {version, blob} when is_integer(version) and version > 0 and is_binary(blob) ->
        {:ok, {version, blob}}

      _ ->
        {:error, :malformed_manifest_file}
    end
  rescue
    ArgumentError -> {:error, :malformed_manifest_file}
  end
end
