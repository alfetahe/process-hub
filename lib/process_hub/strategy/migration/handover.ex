defmodule ProcessHub.Strategy.Migration.HandoverBehaviour do
  @moduledoc """
  Shared behaviour for migration state handover callbacks.

  This behaviour defines the callbacks used by both `HotSwap` and `ColdSwap`
  migration strategies for state handover during process migration.

  Implement these callbacks to customize how state is prepared before
  migration and how it's applied to the new process.
  """

  @doc """
  Called on the dying process to prepare state before migration.
  Return the state data to be transferred to the new process.

  The default implementation returns the state unchanged.
  """
  @callback prepare_handover_state(state :: term()) :: term()

  @doc """
  Called on the new process to apply the handover state.
  Return the new state for the process.

  The default implementation replaces the current state with the handover state.
  """
  @callback alter_handover_state(current_state :: term(), handover_state :: term()) :: term()

  @doc false
  # The behaviour declaration, default callbacks and the forwarded-messages
  # handler that the `HotSwap` and `ColdSwap` `use` macros share.
  def __default_callbacks__ do
    quote do
      @behaviour ProcessHub.Strategy.Migration.HandoverBehaviour

      @impl ProcessHub.Strategy.Migration.HandoverBehaviour
      def prepare_handover_state(state), do: state

      @impl ProcessHub.Strategy.Migration.HandoverBehaviour
      def alter_handover_state(_current_state, handover_state), do: handover_state

      defoverridable prepare_handover_state: 1, alter_handover_state: 2

      @doc false
      def handle_info({:process_hub, :forwarded, _child_id, messages}, state),
        do: ProcessHub.Strategy.Migration.HandoverBehaviour.forwarded(messages, state)
    end
  end

  # The process dictionary keys of the new process: whether its handed-over
  # state arrived, and the passed-on messages that came before it.
  @handed_over :process_hub_handed_over
  @early :process_hub_forwarded_early

  @doc false
  # Old process, right after its state was sent with `forward_messages` on. It
  # runs none of its own callbacks from here: every message is kept until the
  # hub names the new process (`HotSwap`, `:forward_to`) or stops this one
  # (`ColdSwap`, the kept messages go into the hub's storage beside the state).
  # When neither happens within `ttl`, it goes back to work and handles the
  # kept messages itself.
  @spec keep_messages(
          :hot | :cold,
          ProcessHub.child_id(),
          {ProcessHub.hub_id(), pos_integer()},
          term()
        ) ::
          {:noreply, term()} | {:stop, term(), term()}
  def keep_messages(swap, child_id, {hub_id, ttl}, state) do
    ctx = %{
      swap: swap,
      child_id: child_id,
      hub_id: hub_id,
      ttl: ttl,
      state: state,
      parent: parent(),
      trapping?: Process.flag(:trap_exit, true)
    }

    keeping(ctx, [], System.monotonic_time(:millisecond) + ttl)
  end

  defp keeping(ctx, kept, deadline) do
    receive do
      {:process_hub, :forward_to, child_id, pid} when child_id === ctx.child_id ->
        send(pid, {:process_hub, :forwarded, child_id, passable(Enum.reverse(kept))})
        forwarding(ctx, pid)

      {:EXIT, from, reason} = msg ->
        case exit_signal(ctx, from, reason) do
          {:stop, reason} -> stop(ctx, kept, nil, reason)
          :ignore -> keeping(ctx, kept, deadline)
          :message -> keeping(ctx, [msg | kept], deadline)
        end

      msg ->
        keeping(ctx, [msg | kept], deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Process.flag(:trap_exit, ctx.trapping?)
        kept |> Enum.reverse() |> Enum.each(&send(self(), &1))
        {:noreply, ctx.state}
    end
  end

  defp forwarding(ctx, pid) do
    receive do
      {:EXIT, from, reason} ->
        case exit_signal(ctx, from, reason) do
          {:stop, reason} -> stop(ctx, [], pid, reason)
          _not_passed_on -> forwarding(ctx, pid)
        end

      msg ->
        pass_on(ctx, pid, [msg])
    end
  end

  defp pass_on(ctx, pid, messages) do
    with [_ | _] = messages <- passable(messages),
         do: send(pid, {:process_hub, :forwarded, ctx.child_id, messages})

    forwarding(ctx, pid)
  end

  # The old process's own monitor and link notices mean nothing to the new
  # one. They are kept while the old process may still go back to work.
  defp passable(messages) do
    Enum.reject(messages, fn
      {:DOWN, _ref, _type, _object, _info} -> true
      {:EXIT, _from, _reason} -> true
      _msg -> false
    end)
  end

  # Stopped: what is still in the mailbox goes with the kept messages, to the
  # new process, or for `ColdSwap` into the storage the hub delivers it from.
  # A `HotSwap` process stopped before the hub named its replacement has nobody
  # to pass them to.
  defp stop(ctx, kept, pid, reason) do
    messages = passable(Enum.reverse(kept, drain([])))

    cond do
      messages === [] -> :ok
      is_pid(pid) -> send(pid, {:process_hub, :forwarded, ctx.child_id, messages})
      ctx.swap === :cold -> store_kept(ctx, messages)
      true -> :ok
    end

    {:stop, reason, ctx.state}
  end

  defp drain(acc) do
    receive do
      msg -> drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp store_kept(ctx, messages) do
    case ProcessHub.Hub.get(ctx.hub_id) do
      nil ->
        :ok

      hub ->
        ProcessHub.Service.Storage.insert(
          hub.storage.misc,
          {:coldswap_kept, ctx.child_id},
          messages,
          ttl: ctx.ttl
        )
    end
  end

  # The parent stopping this process ends it. Otherwise an exit signal is an
  # ordinary message for a process that traps exits itself, and for one that
  # does not, ends it as it would have, unless the reason is `:normal`.
  defp exit_signal(ctx, from, reason) do
    cond do
      from === ctx.parent -> {:stop, reason}
      ctx.trapping? -> :message
      reason === :normal -> :ignore
      true -> {:stop, reason}
    end
  end

  defp parent() do
    case Process.get(:"$ancestors") do
      [pid | _] when is_pid(pid) -> pid
      [name | _] when is_atom(name) -> Process.whereis(name)
      _ -> nil
    end
  end

  @doc false
  # New process: its handed-over state was applied. Passed-on messages that
  # arrived before it are handled now, after the state.
  @spec handed_over(term()) :: {:noreply, term()}
  def handed_over(state) do
    Process.put(@handed_over, true)
    replay(Process.delete(@early) || [])
    {:noreply, state}
  end

  @doc false
  # New process: messages the old process kept or received after its state was
  # read. Each is sent to this process again, so it is handled as if it had
  # been sent here, a call answered to its caller included. Ones that arrive
  # before the handed-over state wait for it.
  @spec forwarded([term()], term()) :: {:noreply, term()}
  def forwarded(messages, state) do
    if Process.get(@handed_over),
      do: replay(messages),
      else: Process.put(@early, (Process.get(@early) || []) ++ messages)

    {:noreply, state}
  end

  defp replay(messages), do: Enum.each(messages, &send(self(), &1))
end
