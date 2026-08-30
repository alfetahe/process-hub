defmodule ProcessHub.Storage.RemoteManifest.S3 do
  @moduledoc """
  S3 adapter for `ProcessHub.Storage.RemoteManifest`, behind the optional
  `:ex_aws_s3` dependency (with `:ex_aws` and an HTTP client configured per its
  documentation). Works with any S3-compatible store.

  > #### Experimental {: .warning}
  >
  > Part of the experimental declared-children feature; may change in future
  > releases.

  Stores one object per hub at `<prefix>/<hub_id>.manifest`. The stored version
  travels in object metadata; `store/4` reads it first and refuses to overwrite
  a higher version, using a conditional `If-Match` on the read ETag so a stale
  writer cannot clobber a copy that changed in between.

  ## Options

  - `:bucket` (required) — bucket name.
  - `:prefix` — key prefix, default `"process_hub/manifest"`.
  - `:request_fun` — 1-arity function receiving a request map
    `%{verb: :head | :get | :put, bucket: b, key: k, body: binary | nil,
    headers: [{name, value}], meta: [{name, value}]}` and returning
    `{:ok, %{status_code: n, headers: [...], body: binary}} | {:error, term}`
    (HTTP failures as `{:error, {:http_error, status, body}}`). Defaults to
    dispatching through `ExAws`; injectable for tests and custom signing.
  """

  @behaviour ProcessHub.Storage.RemoteManifest

  @version_meta "process-hub-manifest-version"

  @impl true
  def store(hub_id, version, blob, opts) do
    case head(hub_id, opts) do
      {:ok, stored_version, _etag} when stored_version >= version ->
        :ok

      {:ok, _stored_version, etag} ->
        put(hub_id, version, blob, opts, [{"If-Match", etag}])

      :not_found ->
        put(hub_id, version, blob, opts, [{"If-None-Match", "*"}])

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def fetch(hub_id, opts) do
    case request(:get, hub_id, nil, [], [], opts) do
      {:ok, %{status_code: 200, body: body, headers: headers}} ->
        case meta_version(headers) do
          nil -> {:error, :manifest_object_missing_version}
          version -> {:ok, {version, body}}
        end

      other ->
        interpret_miss(other)
    end
  end

  @impl true
  def info(opts) do
    %{adapter: :s3, bucket: Keyword.get(opts, :bucket), prefix: prefix(opts)}
  end

  @impl true
  def validate_config(opts) do
    cond do
      not is_binary(Keyword.get(opts, :bucket)) ->
        {:error, {:s3_requires_bucket, opts}}

      Keyword.get(opts, :request_fun) === nil and
          not Code.ensure_loaded?(Module.concat([ExAws, S3])) ->
        {:error, {:missing_dependency, :ex_aws_s3}}

      true ->
        :ok
    end
  end

  defp head(hub_id, opts) do
    case request(:head, hub_id, nil, [], [], opts) do
      {:ok, %{status_code: 200, headers: headers}} ->
        {:ok, meta_version(headers) || 0, header(headers, "ETag") || header(headers, "etag")}

      other ->
        interpret_miss(other)
    end
  end

  defp put(hub_id, version, blob, opts, conditional_headers) do
    meta = [{@version_meta, Integer.to_string(version)}]

    case request(:put, hub_id, blob, conditional_headers, meta, opts) do
      {:ok, %{status_code: code}} when code in 200..299 -> :ok
      # The conditional failed: someone newer wrote in between. Superseded, not
      # an error — the next ship carries the latest version anyway.
      {:error, {:http_error, 412, _}} -> :ok
      {:ok, %{status_code: 412}} -> :ok
      {:error, reason} -> {:error, reason}
      {:ok, other} -> {:error, {:unexpected_response, other}}
    end
  end

  defp interpret_miss({:error, {:http_error, 404, _}}), do: :not_found
  defp interpret_miss({:ok, %{status_code: 404}}), do: :not_found
  defp interpret_miss({:error, reason}), do: {:error, reason}
  defp interpret_miss({:ok, other}), do: {:error, {:unexpected_response, other}}

  defp meta_version(headers) do
    value = header(headers, "x-amz-meta-#{@version_meta}")

    case value && Integer.parse(value) do
      {version, ""} when version > 0 -> version
      _ -> nil
    end
  end

  defp header(headers, name) do
    downcased = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) === downcased, do: value
    end)
  end

  defp request(verb, hub_id, body, headers, meta, opts) do
    req = %{
      verb: verb,
      bucket: Keyword.fetch!(opts, :bucket),
      key: key(hub_id, opts),
      body: body,
      headers: headers,
      meta: meta
    }

    case Keyword.get(opts, :request_fun) do
      fun when is_function(fun, 1) -> fun.(req)
      nil -> ex_aws_request(req)
    end
  end

  # The only path that touches ExAws, resolved at runtime so the module
  # compiles and loads without the optional dependency.
  defp ex_aws_request(req) do
    s3 = Module.concat([ExAws, S3])

    operation =
      case req.verb do
        :head ->
          apply(s3, :head_object, [req.bucket, req.key])

        :get ->
          apply(s3, :get_object, [req.bucket, req.key])

        :put ->
          apply(s3, :put_object, [
            req.bucket,
            req.key,
            req.body,
            [meta: req.meta, headers: req.headers]
          ])
      end

    apply(Module.concat([ExAws]), :request, [operation])
  end

  defp prefix(opts), do: Keyword.get(opts, :prefix, "process_hub/manifest")
  defp key(hub_id, opts), do: "#{prefix(opts)}/#{hub_id}.manifest"
end
