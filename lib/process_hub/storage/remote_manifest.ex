defmodule ProcessHub.Storage.RemoteManifest do
  @moduledoc """
  Behaviour for off-cluster declared-list storage.

  > #### Experimental {: .warning}
  >
  > The remote manifest is part of the experimental declared-children feature
  > and may change in future releases.

  A hub configured with `auto_recovery: [remote_manifest: {module, opts}]` ships
  every declared-list version to `module` asynchronously after the local commit
  (leader-only, retried with backoff, coalescing superseded versions) and
  consults it on boot: the higher version wins, whichever side holds it. The
  remote copy is what survives the loss of every cluster disk — it is a backup
  consulted at the edges, never a synchronous dependency of any command.

  Built-in adapters: `ProcessHub.Storage.RemoteManifest.LocalPath`
  (dependency-free filesystem path) and `ProcessHub.Storage.RemoteManifest.S3`
  (behind the optional `:ex_aws_s3` dependency). Any module implementing this
  behaviour can be configured instead; the shared contract test suite under
  `test/support` verifies an implementation.

  ## Contract

  - `c:store/4` MUST NOT overwrite a stored copy whose version is higher than
    the one being written, on backends that can express the check — a stale
    leader must not clobber a newer copy. Writing the version already stored is
    an idempotent `:ok`.
  - `c:fetch/2` returns the stored `{version, blob}`, `:not_found` when the
    backend holds no copy for the hub, or `{:error, reason}` when it cannot
    tell.
  - `c:info/1` returns a descriptive map for diagnostics.
  - The optional `c:validate_config/1` runs at hub start; returning
    `{:error, reason}` fails the start with a clear error (e.g. a missing
    optional dependency).

  The blob is opaque to the adapter; it stores and returns it byte-identical.
  """

  @doc """
  Stores `blob` as the manifest for `hub_id` at `version`.

  MUST refuse (with `:ok`, treating it as superseded, or `{:error, term}`) to
  replace a stored copy carrying a higher version where the backend can express
  the check.
  """
  @callback store(
              hub_id :: atom(),
              version :: pos_integer(),
              blob :: binary(),
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @doc "Returns the stored manifest for `hub_id`."
  @callback fetch(hub_id :: atom(), opts :: keyword()) ::
              {:ok, {version :: pos_integer(), blob :: binary()}} | :not_found | {:error, term()}

  @doc "Returns a descriptive map about the adapter and its target."
  @callback info(opts :: keyword()) :: map()

  @doc "Optional start-time configuration check; an error fails hub start."
  @callback validate_config(opts :: keyword()) :: :ok | {:error, term()}

  @optional_callbacks validate_config: 1

  @doc """
  Validates a `remote_manifest:` configuration value at hub start.

  Returns `:ok` for `nil`. For `{module, opts}` the module must be loadable and
  implement the behaviour; its own `validate_config/1` runs when exported, so an
  adapter whose optional dependency is absent fails with an error naming it.
  """
  @spec validate({module(), keyword()} | nil) :: :ok | {:error, term()}
  def validate(nil), do: :ok

  def validate({module, opts}) when is_atom(module) and is_list(opts) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:remote_manifest_module_missing, module}}

      not function_exported?(module, :store, 4) or not function_exported?(module, :fetch, 2) ->
        {:error, {:remote_manifest_not_an_adapter, module}}

      function_exported?(module, :validate_config, 1) ->
        module.validate_config(opts)

      true ->
        :ok
    end
  end

  def validate(_), do: {:error, :remote_manifest_invalid_shape}

  @doc "Encodes a declared-list manifest into the blob adapters store and return."
  @spec encode(map()) :: binary()
  def encode(manifest), do: :erlang.term_to_binary(manifest)

  @doc """
  Decodes a blob returned by an adapter back into a manifest map, validating
  its shape. Format acceptance is the reader's decision, not the codec's.
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, :malformed_remote_manifest}
  def decode(blob) when is_binary(blob) do
    case :erlang.binary_to_term(blob) do
      %{format: format, version: _, mutated_by: _, entries: %{}} = manifest
      when is_integer(format) and format > 0 ->
        {:ok, manifest}

      _ ->
        {:error, :malformed_remote_manifest}
    end
  rescue
    ArgumentError -> {:error, :malformed_remote_manifest}
  end

  def decode(_), do: {:error, :malformed_remote_manifest}
end
