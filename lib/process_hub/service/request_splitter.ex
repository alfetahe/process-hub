defmodule ProcessHub.Service.RequestSplitter do
  @moduledoc """
  Service for splitting large cross-node requests into smaller batches.
  """

  alias ProcessHub.Request.Handler.StartChildrenRequest.ChildStartRequest
  alias ProcessHub.Request.Handler.StopChildrenRequest.ChildStopRequest
  alias ProcessHub.Request.Handler.PidsRegisterRequest
  alias ProcessHub.Request.Handler.PidsUnregisterRequest

  @max_children_per_request 1000
  @max_pids_per_request 10_000

  @spec split(struct()) :: [struct()]
  def split(%ChildStartRequest{children: children} = req)
      when length(children) <= @max_children_per_request,
      do: [req]

  def split(%ChildStartRequest{children: children} = req) do
    children
    |> Enum.chunk_every(@max_children_per_request)
    |> Enum.map(fn chunk -> %{req | children: chunk} end)
  end

  def split(%ChildStopRequest{children: children} = req)
      when length(children) <= @max_children_per_request,
      do: [req]

  def split(%ChildStopRequest{children: children} = req) do
    children
    |> Enum.chunk_every(@max_children_per_request)
    |> Enum.map(fn chunk -> %{req | children: chunk} end)
  end

  def split(%PidsRegisterRequest{children_data: data} = req)
      when map_size(data) <= @max_pids_per_request,
      do: [req]

  def split(%PidsRegisterRequest{children_data: data}) do
    data
    |> Map.to_list()
    |> Enum.chunk_every(@max_pids_per_request)
    |> Enum.map(fn chunk -> %PidsRegisterRequest{children_data: Map.new(chunk)} end)
  end

  def split(%PidsUnregisterRequest{removable_cid_nodes: data} = req)
      when length(data) <= @max_pids_per_request,
      do: [req]

  def split(%PidsUnregisterRequest{removable_cid_nodes: data}) do
    data
    |> Enum.chunk_every(@max_pids_per_request)
    |> Enum.map(fn chunk -> %PidsUnregisterRequest{removable_cid_nodes: chunk} end)
  end

  def split(request), do: [request]
end
