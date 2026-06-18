defmodule ProcessHub.Utility.TimerMap do
  @moduledoc """
  Per-key timer bookkeeping over a plain map of `key => timer_ref`.

  Used for fail-safe timers that must be tracked and cancelled per key (e.g.
  per-node reconciliation), re-arming cleanly when a key flaps by cancelling
  any pending timer before scheduling a new one. All timers are delivered to
  the calling process via `Process.send_after/3`.
  """

  @type t() :: %{optional(term()) => reference()}

  @doc "Schedules `msg` to the caller after `delay` ms under `key`, cancelling any timer already tracked for it."
  @spec put(t(), term(), term(), non_neg_integer()) :: t()
  def put(timers, key, msg, delay) do
    timers = cancel(timers, key)
    ref = Process.send_after(self(), msg, delay)
    Map.put(timers, key, ref)
  end

  @doc "Cancels and drops the timer tracked under `key`, if any. Returns the updated map."
  @spec cancel(t(), term()) :: t()
  def cancel(timers, key) do
    case Map.pop(timers, key) do
      {nil, _} ->
        timers

      {ref, rest} ->
        Process.cancel_timer(ref)
        rest
    end
  end

  @doc "Cancels the timers tracked under each of `keys`. Returns the updated map."
  @spec cancel_all(t(), [term()]) :: t()
  def cancel_all(timers, keys) do
    Enum.reduce(keys, timers, fn key, acc -> cancel(acc, key) end)
  end
end
