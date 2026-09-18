defmodule ProcessHub.Worker.WorkerQueue do
  alias ProcessHub.Request.CrossNodeRequest
  alias ProcessHub.Request.Handler.StartChildrenRequest
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.LoggerService
  alias ProcessHub.Service.Storage

  use GenServer

  def start_link({hub_id, pname, misc_storage}) do
    GenServer.start_link(__MODULE__, {hub_id, misc_storage}, name: pname)
  end

  @impl true
  def init({hub_id, _misc_storage}) do
    {:ok, %{hub_id: hub_id}}
  end

  @impl true
  def handle_cast({:tracked, message, notify_pid}, state) do
    {message, notify_pids, tail} = merge_start_batches(message, [notify_pid])
    run(message)
    Enum.each(notify_pids, &send(&1, :work_complete))

    case tail do
      nil ->
        :ok

      {tail_message, tail_pid} ->
        run(tail_message)
        send(tail_pid, :work_complete)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(message, state) do
    run(message)

    {:noreply, state}
  end

  @impl true
  def handle_call({:handle_work, func}, _from, state) do
    {:reply, func.(), state}
  end

  # A failing job costs only itself: the queue goes on to the next one, and a
  # tracked job still reports back, so the coordinator's lock count drains.
  defp run(message) do
    do_work(message)
  catch
    kind, reason ->
      LoggerService.error(
        "Worker queue job @job failed: @reason",
        %{"job" => elem(message, 0), "reason" => Exception.format(kind, reason, __STACKTRACE__)},
        prefix: "WorkerQueue"
      )
  end

  defp do_work({:handle_work, func}), do: func.()

  defp do_work({:handle_requests, requests, hub}),
    do: do_work({:handle_request_batch, Enum.map(requests, &{&1, hub})})

  # Each request runs against the hub snapshot it was dispatched with.
  defp do_work({:handle_request_batch, [{_request, hub} | _] = pairs}) do
    Task.async_stream(pairs, fn {request, hub} -> CrossNodeRequest.handle(request, hub) end,
      timeout: Storage.get(hub.storage.misc, StorageKey.cnrt()) || 5000,
      ordered: false,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  defp do_work({:handle_request_batch, []}), do: :ok

  defp do_work({:handle_node_down, arg}), do: Cluster.handle_node_down(arg)

  defp do_work({:handle_node_up, arg}), do: Cluster.handle_node_up(arg)

  # Start operations already queued behind this one join its batch, so their
  # registrations share one registry sync instead of paying one each. The
  # first queued message that is not a start batch ends the merge and runs
  # right after it, so the order between a start and a stop of the same child
  # — or any other work — is the order it was queued in.
  defp merge_start_batches({:handle_requests, requests, hub} = message, notify_pids) do
    if start_batch?(requests) do
      drain_start_batches(Enum.map(requests, &{&1, hub}), notify_pids)
    else
      {message, notify_pids, nil}
    end
  end

  defp merge_start_batches(message, notify_pids), do: {message, notify_pids, nil}

  defp drain_start_batches(pairs, notify_pids) do
    receive do
      {:"$gen_cast", {:tracked, {:handle_requests, more, hub} = tail, pid}} ->
        if start_batch?(more) do
          drain_start_batches(pairs ++ Enum.map(more, &{&1, hub}), [pid | notify_pids])
        else
          {{:handle_request_batch, pairs}, notify_pids, {tail, pid}}
        end

      {:"$gen_cast", {:tracked, tail, pid}} ->
        {{:handle_request_batch, pairs}, notify_pids, {tail, pid}}
    after
      0 -> {{:handle_request_batch, pairs}, notify_pids, nil}
    end
  end

  defp start_batch?([_ | _] = requests),
    do: Enum.all?(requests, &match?(%StartChildrenRequest{}, &1))

  defp start_batch?(_requests), do: false
end
