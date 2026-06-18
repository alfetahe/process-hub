defmodule ProcessHub.Constant.RecoveryState do
  @moduledoc """
  Named constants for the three coordinator boot-recovery states.

  > #### Experimental {: .warning}
  >
  > Coordinator boot recovery is experimental and may change in future releases.
  > Use in production at your own discretion.

  When `auto_recovery` is enabled, the coordinator transitions through these
  states during start-up. When `auto_recovery` is disabled, the coordinator's
  `:recovery_state` field is set to `:normal` at `init/1` time and never
  transitions.

  See `guides/Persistence.md` for the full state-machine description.
  """

  @typedoc """
  Initial state when `auto_recovery` is enabled. The coordinator is gathering
  peer information to decide whether to replay locally.
  """
  @type recovery_pending() :: :recovery_pending

  @typedoc """
  The coordinator is iterating the persisted registry and dispatching
  `start_children` calls.
  """
  @type recovering() :: :recovering

  @typedoc """
  Terminal state — the coordinator is fully operational. Reachable from
  `:recovery_pending` (deferred path) and from `:recovering` (replay
  completed or timed out).
  """
  @type normal() :: :normal

  @type t() :: recovery_pending() | recovering() | normal()

  @doc "Returns the `:recovery_pending` atom."
  @spec recovery_pending() :: recovery_pending()
  def recovery_pending(), do: :recovery_pending

  @doc "Returns the `:recovering` atom."
  @spec recovering() :: recovering()
  def recovering(), do: :recovering

  @doc "Returns the `:normal` atom."
  @spec normal() :: normal()
  def normal(), do: :normal

  @doc "Returns all valid recovery-state atoms."
  @spec all() :: [t()]
  def all(), do: [:recovery_pending, :recovering, :normal]
end
