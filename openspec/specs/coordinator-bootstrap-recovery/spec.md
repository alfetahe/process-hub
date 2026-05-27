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

`ProcessHub.t()` SHALL include the existing optional field `:auto_recovery`
accepting these shapes:

- `false` — default. Coordinator transitions immediately to `:normal`; the
  marker gate is disabled; the DETS-read-on-open path behaves exactly as before
  this change. Library tests and single-node deployments are unaffected.
- `true` — enable with default options. Marker gate is active; DETS-read on
  open is gated; `prepare_recovery` API is enabled.
- `keyword()` — accepts the existing
  `recovery_window_ms: integer()` (default `10_000`, range `[1_000, 600_000]`)
  and `replay_timeout_ms: integer()` (default `60_000`, range `[1_000, 3_600_000]`),
  and the new `recovery_timeout_ms: integer()` (default `30_000`, range
  `[1_000, 600_000]`) for the event-queue gate ceiling.

A separate optional field `:recovery_marker` (added in this change) accepts
`%{enabled?: boolean(), path: nil | String.t()}`. When absent, defaults are
`%{enabled?: <auto_recovery enabled?>, path: nil}` and the marker path is
resolved via `:filename.basedir(:user_data, "process_hub") /
<hub_id>/cluster.healthy`.

The field SHALL be ignored by the coordinator if its value is anything other
than the documented shapes; an INVALID-config WARN log SHALL fire and the
coordinator SHALL behave as if `auto_recovery == false`.

#### Scenario: Default config — marker logic disabled, no DETS read on open

- **GIVEN** a hub started with `auto_recovery: false` (or unset)
- **WHEN** the coordinator initialises with `registry_backend: {:dets, []}` and
  3 persisted rows
- **THEN** the in-memory registry does **not** load those 3 rows
  (DETS-read-on-open is gated by the resolved mode, which is "disabled" in this
  case → behaves as a no-op replay)
- **AND** `recovery_state` is `:normal` from the moment `init/1` returns

> Implementation note: When the marker gate is disabled the DETS read path was
> never the source of correctness for cluster registry state — peers always
> dominate via `init_sync`. The existing "library + single-node tests" suites
> rely on the in-memory registry starting empty after a fresh `init/1`; this
> requirement makes that explicit. (This codifies and preserves the pre-change
> single-node test-suite behaviour.)

#### Scenario: Custom window, replay timeout, and recovery timeout

- **GIVEN** `auto_recovery: [recovery_window_ms: 30_000, replay_timeout_ms:
  120_000, recovery_timeout_ms: 45_000]`
- **WHEN** the coordinator initialises
- **THEN** the recovery-window timer fires after 30 s; the replay-loop ceiling
  is 120 s; the cluster-event queue gate ceiling is 45 s

#### Scenario: Out-of-range recovery_timeout_ms rejected

- **GIVEN** `auto_recovery: [recovery_timeout_ms: 100]` (below `1_000` minimum)
- **WHEN** the coordinator initialises
- **THEN** init fails with `{:error, {:invalid_auto_recovery,
  :recovery_timeout_ms_out_of_range}}`

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

The coordinator SHALL execute the replay sequence below when it transitions from `:recovery_pending` to `:recovering` (marker absent in `auto` mode, or `PROCESS_HUB_RECOVERY_MODE=force`):

1. Emit `[:process_hub, :recovery, :started]` telemetry with `%{cspec_count: N}`
   measurement and `%{hub_id: id, mode: mode}` metadata.
2. Dispatch the `pre_recovery_replay` hook synchronously (blocking variant) —
   handlers can inspect or block until prerequisite services are ready. Default
   handler: none.
3. Iterate the persistent registry via `ProcessRegistry.dump(hub_id)` and project
   each row to its `child_spec` only — node-pids and metadata are **not** loaded
   into the in-memory registry. Binding state SHALL be recomputed by the first
   migration tick after the cluster forms.
4. For each cspec, call `Distributor.compose_start_request(state, [cspec], opts)`
   with `opts` containing `:auto_recovery_replay: true` so downstream code can
   identify the call source.
5. Per-cspec failures SHALL be logged at WARN with `child_id` and reason but SHALL
   NOT abort the replay loop. Replay is best-effort; partial-success is
   acceptable.
6. Open the cluster-event queue gate when every cspec has been attempted OR when
   `recovery_timeout_ms` (new config key) fires, whichever first. Emit
   `[:process_hub, :recovery, :complete]` or `[:process_hub, :recovery, :timeout]`
   accordingly.
7. Dispatch the `post_recovery_replay` hook (async).
8. Write the recovery marker to disk.
9. Transition to `:normal`.

Replay SHALL load **cspecs only**. The existing assumption that recovery restores
node-pids and bindings from DETS is removed — bindings are always recomputed by
the migration strategy on the first post-cluster-formation tick.

The previous `replay_timeout_ms` keeps its meaning as an upper bound on the
*replay loop itself* (kept for back-compat); the new `recovery_timeout_ms` is the
upper bound on the *event-queue gate*. When both fire, the earlier of the two
opens the gate.

#### Scenario: Empty registry replay completes immediately

- **GIVEN** a hub with `auto_recovery: true`, marker absent, and either
  `registry_backend: :ets` or `:dets` with no persisted rows
- **WHEN** the recovery path runs
- **THEN** `:started` fires with `cspec_count: 0`; iteration is empty
- **AND** `:complete` fires with `cspec_count: 0, succeeded: 0, failed: 0`;
  marker is written; coordinator transitions to `:normal`

#### Scenario: Cspecs-only replay — no stale bindings injected

- **GIVEN** DETS contains a row for `cid_a` with `node_pids: [{n1, dead_pid}]`
  and metadata `%{assigned_executor: "x1"}`
- **WHEN** recovery replay runs on a fresh boot of `n1`
- **THEN** `cid_a` is restarted locally via `Distributor.compose_start_request`
- **AND** the in-memory registry contains the freshly-started pid, never
  `dead_pid`
- **AND** `metadata` is reset (empty) — `assigned_executor` is recomputed by the
  first migration tick after the cluster forms

#### Scenario: Replay timeout — queue gate opens, replay continues

- **GIVEN** 1 000 cspecs in DETS, `recovery_timeout_ms: 1_000`, slow distribution
- **WHEN** at `t = 1 s` only 200 cspecs have been attempted
- **THEN** the cluster-event queue gate opens; coordinator transitions to
  `:normal` with `reason: :recovery_timeout`; `[:process_hub, :recovery,
  :timeout]` fires with `attempted: 200`
- **AND** the remaining 800 attempts continue in the background; subsequent
  cluster events are processed inline

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

Applications using ProcessHub before this change SHALL NOT require any code,
configuration, or dependency modification to continue functioning identically
after this change is merged.

Specifically:

- The `ProcessHub.t()` struct accepts the new fields `:recovery_marker` and the
  new keyword key `:recovery_timeout_ms` inside `:auto_recovery` as
  `nil`/absent and treats them as defaults.
- When `auto_recovery == false` (the default), the marker gate is disabled, no
  marker file is written or read, and the DETS-read-on-open path behaves
  exactly as before this change.
- All existing public functions (`start_link`, `child_spec`, `is_alive?`,
  `start_children`, `stop_children`, `recovery_state/1`, `await_normal/2`)
  have unchanged signatures and behaviour.
- The previous peer-mode-exchange protocol (`@event_recovery_state_query`,
  `@event_recovery_state_announce`) continues to exist for back-compat with
  consumers that already depend on it, but it is **no longer the primary mode
  selector**. With `:auto_recovery: true` and the marker gate enabled, mode is
  resolved from (env > marker > config default) at `init/1`; peer-mode-exchange
  remains as an additional observability and graceful-degradation channel.
- New public functions (`prepare_recovery/1`, `prepare_recovery_cluster/1`) are
  no-ops on hubs where `:recovery_marker.enabled?` is `false` (they return
  `:ok` without doing IO).
- New event `{:cluster_join, {:restarted, node}}` is silently dropped by peers
  running older versions.
- No new required dependencies.

#### Scenario: Pre-change single-node test suite passes unchanged

- **GIVEN** an existing single-node test that uses `auto_recovery: false`
  (default) and `registry_backend: {:dets, []}`
- **WHEN** the suite runs against post-change ProcessHub
- **THEN** all tests pass with no modifications; behaviour at every observation
  point is bit-for-bit identical to pre-change

#### Scenario: First-ever boot with `auto_recovery: true` is a no-op recovery

- **GIVEN** a fresh deployment with `auto_recovery: true`, marker absent, and
  DETS empty (first boot ever)
- **WHEN** the coordinator initialises
- **THEN** recovery runs against an empty DETS (`cspec_count: 0`, no-op)
- **AND** the marker is written; the hub transitions to `:normal`
- **AND** subsequent boots (until `prepare_recovery` is invoked) see the marker
  and skip DETS read entirely

### Requirement: Operator-controlled recovery via marker file

ProcessHub SHALL gate boot-time replay of the persistent registry behind a per-node
**marker file**. The marker is a zero-byte file at a path resolved per hub. When the
marker is present at coordinator init, the hub boots in **normal mode** and SHALL
NOT read any rows from the persistent registry table on open. When the marker is
absent, the hub boots in **recovery mode** and SHALL load every cspec from the
persistent registry, attempt to start each child locally, and only then begin
processing cluster events.

The marker path SHALL be configurable per hub via a new `:recovery_marker` config
key on `ProcessHub.t()`:

- `recovery_marker: %{enabled?: boolean(), path: nil | String.t()}`
- `enabled?: true` (default when `auto_recovery: true`) — the marker gate is active.
- `enabled?: false` — marker gate is disabled; the hub behaves as if always in
  normal mode (no DETS read on boot) regardless of marker presence. This is the
  mode `auto_recovery: false` selects automatically and preserves pre-change
  behaviour bit-for-bit for library tests.
- `path: nil` — resolve to the default
  `<:filename.basedir(:user_data, "process_hub")>/<hub_id>/cluster.healthy`.
  Translated to `/var/lib/process_hub/<hub_id>/cluster.healthy` on standard Linux
  deployments.
- `path: String.t()` — absolute path on the local filesystem.

The marker SHALL be (re)written automatically after every successful boot — both
after a normal-mode boot and after recovery completes (`:recovering → :normal`).
Steady-state operation SHALL never require human attention to the marker.

#### Scenario: Marker present at boot — normal mode, no DETS read

- **GIVEN** a hub with `auto_recovery: true`, `registry_backend: {:dets, []}`, and the
  marker file exists at the resolved path
- **WHEN** the coordinator initialises
- **THEN** the in-memory registry table is empty after `init/1`
- **AND** `ProcessRegistry.dump(hub_id)` returns `[]` immediately after init
- **AND** no child is started from DETS on this node
- **AND** the hub joins the cluster and inherits state from peers via `init_sync`

#### Scenario: Marker absent at boot — recovery mode, DETS replay runs

- **GIVEN** a hub with `auto_recovery: true`, `registry_backend: {:dets, []}`, the
  DETS file contains 3 persisted cspecs, and the marker file does **not** exist
- **WHEN** the coordinator initialises
- **THEN** the recovery-state transitions `:recovery_pending → :recovering`
  *before* any `:nodeup` event is processed
- **AND** each of the 3 cspecs is restarted on the local node via
  `Distributor.compose_start_request/3`
- **AND** after replay completes the coordinator writes the marker file and
  transitions to `:normal`

#### Scenario: Marker (re)written on successful boot

- **GIVEN** any successful boot path (marker-present-normal, marker-absent-recovery,
  or env-forced override)
- **WHEN** the coordinator reaches `:normal`
- **THEN** the marker file exists at the resolved path with a zero-byte payload
- **AND** the next boot with the same persistent state observes the marker and
  selects normal mode

### Requirement: PROCESS_HUB_RECOVERY_MODE env-var override

ProcessHub SHALL honour a `PROCESS_HUB_RECOVERY_MODE` environment variable that
overrides the marker-file-driven mode resolution on a per-node basis. The
resolution precedence at coordinator init SHALL be (highest → lowest):

1. `PROCESS_HUB_RECOVERY_MODE=force` — recover even if the marker is present
2. `PROCESS_HUB_RECOVERY_MODE=skip` — never recover even if the marker is absent
   (start empty; do **not** read DETS; do write the marker on entry to `:normal`)
3. `PROCESS_HUB_RECOVERY_MODE=auto` (default if env var is unset or any other value)
   — marker-driven decision

Unknown or unparseable env-var values SHALL behave as `auto` and SHALL emit a
WARN log identifying the offending value. The env-var SHALL be evaluated **once**
at coordinator `init/1`. Changing the env-var at runtime SHALL NOT change the
hub's already-resolved mode.

#### Scenario: Force override recovers despite marker

- **GIVEN** a hub with marker present and `PROCESS_HUB_RECOVERY_MODE=force` at
  `init/1`
- **WHEN** the coordinator initialises
- **THEN** the hub enters `:recovering` and replays DETS even though the marker
  exists

#### Scenario: Skip override boots empty without DETS read

- **GIVEN** a hub with marker absent, DETS containing 5 cspecs, and
  `PROCESS_HUB_RECOVERY_MODE=skip`
- **WHEN** the coordinator initialises
- **THEN** the in-memory registry is empty
- **AND** no cspec is started from DETS
- **AND** the marker is written on entry to `:normal`

#### Scenario: Unknown env value falls back to auto

- **GIVEN** `PROCESS_HUB_RECOVERY_MODE=garbage`
- **WHEN** the coordinator initialises
- **THEN** a WARN log identifies the value `garbage` as invalid
- **AND** mode is resolved as if the env var were `auto`

### Requirement: Cluster-event queue during recovery

While the coordinator is in `:recovery_pending` or `:recovering`, it SHALL queue
all incoming `:nodeup`, `:nodedown`, and hook events (`@event_cluster_join`,
`@event_cluster_leave`, dispatched hook events) instead of processing them through
the normal handler. BEAM distribution, libcluster, `:global`, and `:net_kernel`
SHALL continue to operate normally — only ProcessHub's own coordinator handlers
are gated.

The queue SHALL drain through the normal handler when **either**:

1. Every cspec read from the persistent registry has been *attempted*
   (success / error / skip — per-cspec errors SHALL NOT block the gate), OR
2. A configurable `recovery_timeout_ms` ceiling fires (new config key, default
   `30_000` ms, range `[1_000, 600_000]`).

Whichever fires first opens the gate. After the gate opens the queue SHALL be
drained in FIFO order and subsequent events SHALL be processed inline by the
normal handler.

#### Scenario: Events queued during recovery, drained on completion

- **GIVEN** a hub in `:recovering` and a peer node joins
- **WHEN** the `:nodeup`/`@event_cluster_join` event arrives at the coordinator
  mid-replay
- **THEN** the event SHALL be appended to the recovery event queue
- **AND** `init_sync` SHALL NOT be invoked for the joining peer until the queue
  drains

#### Scenario: Gate opens on cspec-attempt completion

- **GIVEN** 5 cspecs in DETS at boot
- **WHEN** every cspec has been attempted (3 succeeded, 1 errored, 1 skipped as
  invalid)
- **THEN** the coordinator opens the queue gate and transitions to `:normal`
- **AND** the queued cluster events drain through the normal handler in FIFO
  order

#### Scenario: Gate opens on recovery_timeout_ms ceiling

- **GIVEN** `recovery_timeout_ms: 5_000` and 1 000 cspecs in DETS where replay is
  slow
- **WHEN** at `t = 5 s` only 200 cspecs have been attempted
- **THEN** the coordinator opens the queue gate, transitions to `:normal` with
  `reason: :recovery_timeout`
- **AND** the remaining cspec attempts continue in the background; queued events
  drain immediately

### Requirement: prepare_recovery operator API

ProcessHub SHALL expose two public functions for operators to arm a hub for a
recovery boot:

- `ProcessHub.prepare_recovery(hub_id \\ :default_hub) :: :ok | {:error, term()}` —
  deletes the marker file on the local node. The next coordinator init on this
  node SHALL select recovery mode (subject to env-var precedence). If the marker
  file does not exist the call SHALL be a no-op and return `:ok`.

- `ProcessHub.prepare_recovery_cluster(hub_id \\ :default_hub) ::
  {:ok, [node()]} | {:partial, [node()], [node()]} | {:error, term()}` —
  fans out the `prepare_recovery/1` call via RPC to every member node returned
  by `ProcessHub.Service.Cluster.nodes(hub_id, [:include_local])`. Returns
  `{:ok, acked_nodes}` if every member acknowledged, `{:partial, acked, unreachable}`
  if any member failed to respond or the RPC errored, `{:error, reason}` if the
  cluster API itself failed (e.g. hub not running locally).

Both functions SHALL be safe to call on a running hub — they SHALL only delete
the marker file; they SHALL NOT interrupt the live coordinator. Subsequent
restarts SHALL pick up the marker absence.

#### Scenario: prepare_recovery deletes the marker locally

- **GIVEN** a running hub with the marker present
- **WHEN** `ProcessHub.prepare_recovery(:my_hub)` is invoked
- **THEN** the marker file at the configured path is deleted
- **AND** the call returns `:ok`
- **AND** the running coordinator state is unchanged

#### Scenario: prepare_recovery_cluster fan-out with reachable peers

- **GIVEN** a 3-node cluster, all members reachable
- **WHEN** `ProcessHub.prepare_recovery_cluster(:my_hub)` is invoked on any node
- **THEN** the marker file is deleted on all 3 nodes
- **AND** the call returns `{:ok, [n1, n2, n3]}`

#### Scenario: prepare_recovery_cluster partial reach

- **GIVEN** a 3-node cluster where one peer is unreachable (`:rpc.call` returns
  `{:badrpc, :nodedown}`)
- **WHEN** `ProcessHub.prepare_recovery_cluster(:my_hub)` is invoked
- **THEN** the call returns `{:partial, [acked_node_1, acked_node_2], [down_node]}`
- **AND** the marker is deleted on the two reachable nodes

### Requirement: Fast-restart purge signal within :net_ticktime

The coordinator SHALL broadcast a `{:cluster_join, {:restarted, node()}}` fast-restart purge signal to every reachable peer hub on entering `:normal` (recovery completed OR normal-mode boot), provided the hub detects it is rejoining a cluster where peers may still be holding bindings whose pid lives on `node()` (the previous incarnation).

On receipt of `{:cluster_join, {:restarted, restarted_node}}`, peers SHALL
preemptively purge from their in-memory registry any binding whose `node_pids`
list contains `restarted_node`, **before** the existing `init_sync` flow runs.

This closes the "ghost pid" window when a pod restarts faster than peers detect
the disconnect (i.e. within `:net_ticktime`). Peers running older ProcessHub
versions SHALL silently drop the signal (graceful degradation in mixed-version
clusters — same pattern as the existing `@event_recovery_state_announce`
graceful-degradation requirement).

The signal SHALL be emitted at most once per coordinator lifetime, immediately
before the first `init_sync` of the boot.

#### Scenario: Restart signal purges stale local-node bindings on peers

- **GIVEN** a 2-node cluster A/B; A restarts within `:net_ticktime` (peers still
  hold a binding `{cid, [{A, dead_pid}]}`)
- **WHEN** A enters `:normal` and broadcasts `{:cluster_join, {:restarted, A}}`
- **THEN** B receives the signal and purges every binding whose `node_pids`
  contains `A` from its in-memory registry
- **AND** `init_sync` between A and B then proceeds against B's now-clean state
- **AND** the dead pid does not re-appear in A's merged registry

#### Scenario: Old peer drops the signal silently

- **GIVEN** A runs post-change ProcessHub, B runs pre-change ProcessHub
- **WHEN** A sends `{:cluster_join, {:restarted, A}}` to B
- **THEN** B has no handler for that message variant and silently drops it
- **AND** the existing `init_sync` flow runs; no errors are raised on either side

### Requirement: Recovery telemetry events

ProcessHub SHALL emit `[:telemetry]`-compatible events for the recovery lifecycle:

- `[:process_hub, :recovery, :started]` — emitted when the coordinator enters
  `:recovering`. Measurements: `%{cspec_count: N, system_time: t}`. Metadata:
  `%{hub_id: id, mode: :auto | :force | :skip, marker_path: path | nil}`.
- `[:process_hub, :recovery, :complete]` — emitted when the coordinator
  transitions `:recovering → :normal` after all cspecs have been attempted.
  Measurements: `%{cspec_count, succeeded, failed, skipped, elapsed_ms}`.
  Metadata: `%{hub_id, mode}`.
- `[:process_hub, :recovery, :skipped]` — emitted when recovery is skipped at
  boot (marker present in `auto`, or `PROCESS_HUB_RECOVERY_MODE=skip`).
  Measurements: `%{system_time: t}`. Metadata:
  `%{hub_id, reason: :marker_present | :env_skip | :disabled}`.
- `[:process_hub, :recovery, :timeout]` — emitted when `recovery_timeout_ms`
  fires before every cspec has been attempted. Measurements: `%{cspec_count,
  attempted, elapsed_ms}`. Metadata: `%{hub_id, mode}`.

These events are additive. The existing `recovery_state_changed` hook continues
to fire on every state transition.

#### Scenario: Skipped recovery emits :skipped, not :started

- **GIVEN** marker present, `auto` mode
- **WHEN** the coordinator initialises and transitions directly to `:normal`
- **THEN** exactly one `[:process_hub, :recovery, :skipped]` event is emitted with
  `reason: :marker_present`
- **AND** no `:started` or `:complete` event is emitted

#### Scenario: Recovery completion emits :complete

- **GIVEN** marker absent, 3 cspecs in DETS, all start successfully
- **WHEN** replay finishes
- **THEN** exactly one `:started` and one `:complete` event are emitted in order
- **AND** the `:complete` measurements include `succeeded: 3, failed: 0,
  skipped: 0`

#### Scenario: Recovery timeout emits :timeout

- **GIVEN** `recovery_timeout_ms: 1_000`, 1 000 cspecs in DETS, slow replay
- **WHEN** the ceiling fires at `t = 1 s` with only 100 cspecs attempted
- **THEN** exactly one `[:process_hub, :recovery, :timeout]` event is emitted
  with `attempted: 100`
