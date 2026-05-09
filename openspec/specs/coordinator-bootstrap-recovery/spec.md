# coordinator-bootstrap-recovery Specification

## Purpose

TBD - created from the coordinator-bootstrap-recovery change. Update Purpose after the change is archived.

## Requirements

### Requirement: Three-state coordinator boot lifecycle

`ProcessHub.Coordinator` SHALL implement a three-state boot lifecycle accessible via the `Hub.t()` runtime struct's `:recovery_state` field:

- **`:recovery_pending`** — the initial state when `auto_recovery` is enabled. Means "the system is in recovery mode and gathering peer information to decide whether to replay locally."
- **`:recovering`** — actively iterating the persistent registry and dispatching `start_children` calls.
- **`:normal`** — fully operational. The terminal state. Reachable directly from `:recovery_pending` (deferred to peers) OR from `:recovering` (replay completed or timed out).

When `auto_recovery == false` (the default), the coordinator SHALL set `:recovery_state` to `:normal` at init/1 time and never transition. This preserves all existing behaviour bit-for-bit.

When `auto_recovery == true` (or a keyword list), the coordinator SHALL enter `:recovery_pending` at init/1, schedule a window timer for `recovery_window_ms`, and transition based on the peer-mode-exchange protocol described below.

#### Scenario: Default config — :recovery_state is always :normal

- **GIVEN** a hub started with `auto_recovery: false` (or no `:auto_recovery` field set)
- **WHEN** the coordinator initialises
- **THEN** `Hub.t().recovery_state` is `:normal` from the moment `init/1` returns
- **AND** no recovery-window timer is scheduled
- **AND** no `recovery_state_changed` hook fires (the field starts at `:normal` rather than transitioning to it)

#### Scenario: Opt-in starts in :recovery_pending

- **GIVEN** a hub started with `auto_recovery: true`
- **WHEN** the coordinator initialises
- **THEN** `Hub.t().recovery_state` is `:recovery_pending`
- **AND** a window timer is scheduled for `recovery_window_ms` (default 10_000)

### Requirement: `:auto_recovery` configuration field

`ProcessHub.t()` SHALL include a new optional field `:auto_recovery` accepting these shapes:

- `false` — default. Coordinator transitions immediately to `:normal`.
- `true` — enable with default options.
- `keyword()` — accepts `recovery_window_ms: integer()` (default `10_000`, range `[1_000, 600_000]`) and `replay_timeout_ms: integer()` (default `60_000`, range `[1_000, 3_600_000]`).

The field SHALL be ignored by the coordinator if its value is anything other than the documented shapes; an INVALID-config WARN log SHALL fire and the coordinator SHALL behave as if `auto_recovery == false`.

#### Scenario: Custom window and timeout

- **GIVEN** `auto_recovery: [recovery_window_ms: 30_000, replay_timeout_ms: 120_000]`
- **WHEN** the coordinator initialises
- **THEN** the window timer fires after 30 s; the replay timeout is 120 s

#### Scenario: Out-of-range values clamped or rejected

- **GIVEN** `auto_recovery: [recovery_window_ms: 100]` (below the `1_000` minimum)
- **WHEN** the coordinator initialises
- **THEN** init fails with `{:error, {:invalid_auto_recovery, :recovery_window_ms_out_of_range}}`

### Requirement: Peer-mode exchange protocol

When the coordinator is in `:recovery_pending`, peer connections SHALL trigger a recovery-state exchange:

- On receipt of `@event_cluster_join` for a remote node (existing event), the coordinator SHALL `Dispatcher.propagate_event(state.procs.event_queue, @event_recovery_state_query, node(), %{members: [remote_node]})` to ask the remote for its current state.
- On receipt of `@event_recovery_state_query` from a remote node, the coordinator SHALL respond with `Dispatcher.propagate_event(state.procs.event_queue, @event_recovery_state_announce, {node(), recovery_state}, %{members: [remote_node]})`.
- On receipt of `@event_recovery_state_announce` carrying a peer's state: if the local state is `:recovery_pending` AND the peer reports `:normal`, the coordinator SHALL cancel the window timer and transition to `:normal` (deferred-to-peers path).
- The coordinator SHALL also push its own state changes to all known peers via `@event_recovery_state_announce` so that peers in their own `:recovery_pending` see updates.

When the local state transitions to `:normal` (via either path), the coordinator SHALL broadcast `@event_recovery_state_announce` with `(node(), :normal)` to all currently-known peers.

The events `@event_recovery_state_query` and `@event_recovery_state_announce` SHALL be added to the existing event-queue handler registration. Old ProcessHub versions that lack these handlers SHALL silently drop the events (graceful degradation in mixed-version clusters).

#### Scenario: Single-node-rejoin sees peer :normal and defers

- **GIVEN** node A has `auto_recovery: true` and is starting up; node B is already running with `recovery_state: :normal`
- **WHEN** A's coordinator enters `:recovery_pending` and the existing `@event_cluster_join` handler fires for node B
- **AND** A dispatches `@event_recovery_state_query` to B; B responds with `@event_recovery_state_announce` carrying `:normal`
- **THEN** A's coordinator cancels the recovery-window timer and transitions directly to `:normal` (skip replay)
- **AND** the `recovery_state_changed` hook fires with `%{from: :recovery_pending, to: :normal, reason: :peer_normal, peers: %{B => :normal}}`

#### Scenario: Cluster-wide cold boot — all peers :recovery_pending

- **GIVEN** three nodes A/B/C all booting with `auto_recovery: true`
- **WHEN** they each enter `:recovery_pending` and exchange modes
- **AND** all peers report `:recovery_pending` within the window
- **THEN** each node's window elapses; each transitions to `:recovering`; each runs replay; each transitions to `:normal`
- **AND** subsequent peer announcements of `:normal` reach the others (some may transition first; the others receive the late announce but already in `:recovering` or `:normal` so no further action needed)

#### Scenario: Old peer in mixed-version cluster

- **GIVEN** a cluster of two nodes, A running new ProcessHub, B running pre-change ProcessHub
- **WHEN** A enters `:recovery_pending` and dispatches `@event_recovery_state_query` to B
- **THEN** B has no handler registered for that event and silently drops it
- **AND** A's window elapses without seeing a peer respond `:normal`
- **AND** A transitions to `:recovering` and replays
- **AND** No errors are raised; the lifecycle completes correctly even though B is on the old code

### Requirement: Replay path runs `Distributor.compose_start_request` for each persisted child

When the coordinator transitions from `:recovery_pending` to `:recovering` (window elapsed without a `:normal` peer), it SHALL:

1. Emit `[:process_hub, :coordinator, :recovery_replay_started]` telemetry with `%{child_count: N}` measurement and `%{hub_id: id}` metadata.
2. Dispatch the `pre_recovery_replay` hook synchronously (blocking variant) — handlers can inspect or block until prerequisite services are ready. Default hook handler: none.
3. Iterate the persisted registry via `ProcessRegistry.dump(hub_id)` (which uses the configured backend — `Storage.Ets` returns empty for fresh process; `Storage.Dets` returns persisted rows).
4. For the iteration result, call `Distributor.compose_start_request(state, child_specs, opts)` with `opts` containing `:auto_recovery_replay: true` so downstream code can identify the call source.
5. Wait for the start request to resolve (success or failure for each child) up to `replay_timeout_ms`.
6. Emit `[:process_hub, :coordinator, :recovery_replay_completed]` telemetry with `%{child_count: N, succeeded: S, failed: F, elapsed_ms: T}` measurement.
7. Dispatch the `post_recovery_replay` hook (async).
8. Transition to `:normal`.

Per-child failures during replay SHALL be logged at WARN with the child_id and reason, but SHALL NOT abort the replay loop. Replay is best-effort; partial-success is acceptable.

If `replay_timeout_ms` elapses before replay completes, the coordinator SHALL log WARN, fire `recovery_state_changed` with `reason: :replay_timeout`, and transition to `:normal`. Replay continues in the background; remaining children complete asynchronously.

#### Scenario: Empty registry replay completes immediately

- **GIVEN** a hub with `auto_recovery: true` and `registry_backend: :ets` (or `:dets` with no persisted rows)
- **WHEN** the recovery window elapses; coordinator enters `:recovering`
- **THEN** `recovery_replay_started` fires with `child_count: 0`; iteration is empty
- **AND** `recovery_replay_completed` fires with `child_count: 0, succeeded: 0, failed: 0`; coordinator transitions to `:normal`

#### Scenario: Persisted registry replay distributes via consistent hash

- **GIVEN** a hub with `auto_recovery: true` + `registry_backend: {:dets, []}`; the persisted registry contains 3 children
- **WHEN** all peer nodes are also in `:recovery_pending` and the window elapses on this node
- **THEN** the coordinator iterates the 3 children and calls `Distributor.compose_start_request` for each
- **AND** the distribution strategy places each child according to its hash on the current node ring
- **AND** `start_children` idempotency means duplicate calls from peer-node replays are no-ops
- **AND** the coordinator transitions to `:normal` after all 3 complete

#### Scenario: Replay timeout — coordinator transitions, replay continues

- **GIVEN** 1000 children in the persisted registry, `replay_timeout_ms: 1_000`, slow distribution due to network
- **WHEN** at `t = 1 s`, only 200 children have been started
- **THEN** the coordinator transitions to `:normal` with `recovery_state_changed` `reason: :replay_timeout`
- **AND** the remaining 800 continue starting in the background; they reach `:normal` placement asynchronously without further coordinator state changes

### Requirement: Hook points for downstream integration

Three new hook keys SHALL be available via `ProcessHub.Constant.Hook`:

- `Hook.recovery_state_changed()` — fires on every `recovery_state` transition. Payload: `%{from: state, to: state, reason: atom, peers: %{node => state}}`. Async (fire-and-forget). Replaces no existing hook.
- `Hook.pre_recovery_replay()` — fires once when entering `:recovering`, before any `start_children` is dispatched. Synchronous (blocking) — the coordinator awaits each handler's reply before proceeding. Handlers SHOULD return quickly (the coordinator's reply timeout is `replay_timeout_ms`); long blocks risk forcing the timeout path. Use case: downstream users (e.g. Flezha) ensure prerequisite services (FleetManager, transport listeners) are fully ready before replay starts dispatching.
- `Hook.post_recovery_replay()` — fires once when leaving `:recovering` (whether by completion or timeout). Async. Use case: downstream users mark "boot complete" externally.

These hooks are additive. Existing hook keys are unchanged. Handlers for these hooks are not invoked when `auto_recovery == false`.

#### Scenario: pre_recovery_replay handler can block until FleetManager is ready

- **GIVEN** a downstream application registers a `pre_recovery_replay` handler that waits up to 30 s for `FleetManager` to report ready
- **WHEN** the coordinator enters `:recovering`
- **THEN** the coordinator dispatches the `pre_recovery_replay` hook synchronously
- **AND** the handler blocks until `FleetManager` is ready (or its internal timeout)
- **AND** only after the handler returns does the coordinator begin iterating the registry

#### Scenario: recovery_state_changed fires on every transition

- **WHEN** a coordinator transitions `:recovery_pending → :normal` (deferred path)
- **THEN** exactly one `recovery_state_changed` hook fires with `from: :recovery_pending, to: :normal, reason: :peer_normal`
- **WHEN** another coordinator transitions `:recovery_pending → :recovering → :normal` (replay path)
- **THEN** TWO hooks fire — one for each transition

### Requirement: Public API for recovery-state introspection

`ProcessHub` SHALL expose two new public functions:

- `ProcessHub.recovery_state(hub_id) :: :recovery_pending | :recovering | :normal` — synchronous query of the current state. For hubs with `auto_recovery: false`, ALWAYS returns `:normal`.
- `ProcessHub.await_normal(hub_id, timeout_ms \\ 60_000) :: :ok | {:error, :timeout}` — blocks until the hub's `recovery_state` is `:normal` or the timeout elapses. For hubs with `auto_recovery: false`, returns `:ok` immediately.

Both functions SHALL work for any hub regardless of whether `auto_recovery` is enabled.

#### Scenario: recovery_state returns :normal for non-opted-in hub

- **GIVEN** a hub started with default config
- **WHEN** `ProcessHub.recovery_state(:my_hub)` is called at any point after `init/1`
- **THEN** it returns `:normal`

#### Scenario: await_normal blocks until transition

- **GIVEN** a hub in `:recovery_pending` with a 10 s recovery window and no peer that reports `:normal`
- **WHEN** a caller invokes `ProcessHub.await_normal(:my_hub, 30_000)` at `t = 0`
- **THEN** the call blocks until the coordinator reaches `:normal` (after window + replay)
- **AND** returns `:ok` once the transition completes

#### Scenario: await_normal returns :timeout on long replays

- **GIVEN** a hub whose replay genuinely takes longer than the caller's timeout
- **WHEN** `ProcessHub.await_normal(:my_hub, 5_000)` is called and replay is still ongoing at t=5s
- **THEN** the call returns `{:error, :timeout}`
- **AND** the coordinator continues toward `:normal` independently

### Requirement: Backward compatibility — existing applications need no changes

Applications using ProcessHub before this change SHALL NOT require any code, configuration, or dependency modification to continue functioning identically after this change is merged.

Specifically:

- The `ProcessHub.t()` struct accepts the new field as `nil`/absent and treats it as `false`.
- All existing public functions (`start_link`, `child_spec`, `is_alive?`, `start_children`, `stop_children`, etc.) have unchanged signatures and behaviour.
- New hooks are not invoked unless `auto_recovery` is enabled — existing hook handlers are unaffected.
- New events (`@event_recovery_state_query`, `@event_recovery_state_announce`) are dropped silently by old peers; mixed-version clusters function correctly.
- New public functions (`recovery_state/1`, `await_normal/2`) work for any hub, behaving as if `:normal` for non-opted-in hubs.
- No new required dependencies.

#### Scenario: Pre-change application unmodified after upgrade

- **GIVEN** an application's `mix.exs`, `config/*.exs`, and ProcessHub child_spec are unchanged from before this change
- **WHEN** the application is rebuilt against post-change ProcessHub
- **THEN** all existing tests pass; behaviour is bit-for-bit identical to pre-change at every observation point

#### Scenario: Mixed-version cluster operates correctly

- **GIVEN** a cluster where node A runs post-change ProcessHub and node B runs pre-change ProcessHub
- **WHEN** A starts up with `auto_recovery: true` and connects to B
- **THEN** A's recovery-state-query events to B are dropped silently by B (no handler); A's window elapses; A transitions to `:recovering` and replays
- **AND** B continues operating normally; no errors are raised on either side
