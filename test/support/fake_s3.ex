defmodule Test.Support.FakeS3 do
  @moduledoc """
  In-memory S3 stand-in for the `RemoteManifest.S3` adapter's `:request_fun`.

  Honors the request map contract the adapter emits — HEAD/GET/PUT with
  `If-Match`/`If-None-Match` conditional semantics and `x-amz-meta-*` metadata —
  so the adapter's whole logic runs against it without the optional dependency.
  """

  def start_link do
    Agent.start_link(fn -> %{} end)
  end

  @doc "Returns the adapter's `:request_fun` bound to the given store."
  def request_fun(agent) do
    fn req -> handle(agent, req) end
  end

  defp handle(agent, %{verb: :head, bucket: bucket, key: key}) do
    case get_object(agent, bucket, key) do
      nil -> {:error, {:http_error, 404, "not found"}}
      object -> {:ok, %{status_code: 200, headers: object.headers, body: ""}}
    end
  end

  defp handle(agent, %{verb: :get, bucket: bucket, key: key}) do
    case get_object(agent, bucket, key) do
      nil -> {:error, {:http_error, 404, "not found"}}
      object -> {:ok, %{status_code: 200, headers: object.headers, body: object.body}}
    end
  end

  defp handle(agent, %{verb: :put, bucket: bucket, key: key} = req) do
    Agent.get_and_update(agent, fn store ->
      existing = Map.get(store, {bucket, key})

      case check_conditions(req.headers, existing) do
        :ok ->
          etag = "etag-#{System.unique_integer([:positive])}"

          headers =
            [{"ETag", etag}] ++
              Enum.map(req.meta, fn {name, value} -> {"x-amz-meta-#{name}", value} end)

          object = %{body: req.body, headers: headers}

          {{:ok, %{status_code: 200, headers: headers, body: ""}},
           Map.put(store, {bucket, key}, object)}

        :precondition_failed ->
          {{:error, {:http_error, 412, "precondition failed"}}, store}
      end
    end)
  end

  defp get_object(agent, bucket, key) do
    Agent.get(agent, &Map.get(&1, {bucket, key}))
  end

  defp check_conditions(headers, existing) do
    cond do
      {"If-None-Match", "*"} in headers and existing != nil -> :precondition_failed
      match = List.keyfind(headers, "If-Match", 0) -> if_match(match, existing)
      true -> :ok
    end
  end

  defp if_match({"If-Match", etag}, existing) do
    case existing do
      %{headers: headers} ->
        if {"ETag", etag} in headers, do: :ok, else: :precondition_failed

      nil ->
        :precondition_failed
    end
  end
end
