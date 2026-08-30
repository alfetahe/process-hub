# coordinator-bootstrap-recovery Specification

## Purpose

TBD - created from the coordinator-bootstrap-recovery change. Update Purpose after the change is archived.
## Requirements
### Requirement: Three-state coordinator boot lifecycle

`ProcessHub.Coordinator` SHALL implement a two-state boot lifecycle accessible via the
`Hub.t()` runtime struct's `:recovery_state` field:

- **`:recovering`** — the initial state when `auto_recovery` is enabled. Means "this
  node's durable registry has not yet been reconciled against the cluster". Cluster
  events are processed normally in this state; nothing is gated.
- **`:normal`** — the first orphan reconcile round has completed. Terminal state.

When `auto_recovery == false` (the default), the coordinator SHALL set `:recovery_state`
to `:normal` at `init/1` and never transition, and SHALL run no reconcile rounds. This
preserves pre-change behaviour for hubs that never opted in.

The transition to `:normal` SHALL occur when the first reconcile round completes. That
round runs when `reconcile_grace_ms` elapses whether or not any peer has joined, so
`:normal` is reached in bounded time on every boot, including a single node booting
alone.

`:recovery_pending` is removed. It named the window between init and the start of boot
replay, which no longer exists.

#### Scenario: Default config — :recovery_state is always :normal

- **GIVEN** a hub started with `auto_recovery: false` (or no `:auto_recovery` field set)
- **WHEN** the coordinator initialises
- **THEN** `Hub.t().recovery_state` is `:normal` from the moment `init/1` returns
- **AND** no reconcile round is ever scheduled
- **AND** no `recovery_state_changed` hook fires

#### Scenario: Opt-in hub starts in :recovering and settles

- **GIVEN** a hub started with `auto_recovery: true` and `reconcile_grace_ms: 30_000`
- **WHEN** the coordinator initialises
- **THEN** `Hub.t().recovery_state` is `:recovering`
- **AND** cluster events are processed inline from that moment
- **AND** after the first reconcile round completes, `recovery_state` is `:normal` and
  one `recovery_state_changed` hook has fired with
  `%{from: :recovering, to: :normal, reason: :reconcile_complete}`

#### Scenario: A node alone still reaches :normal

- **GIVEN** an opt-in hub booting with no reachable peers
- **WHEN** `reconcile_grace_ms` elapses
- **THEN** the first round runs against an empty cluster view and the coordinator
  transitions to `:normal`

### Requirement: `:auto_recovery` configuration field

`ProcessHub.t()` SHALL include the optional field `:auto_recovery` as the single
configuration entry point for registry convergence and orphan recovery, accepting:

- `false` — default. No reconcile rounds, no epoch stamping beyond what a single node
  writes locally, `recovery_state` is `:normal` from init. Library tests and
  single-node deployments are unaffected.
- `true` — enable with defaults.
- `keyword()` — accepts
  `reconcile_grace_ms: integer()` (default `30_000`, range `[1_000, 600_000]`),
  `reconcile_interval_ms: integer()` (default `15_000`, range `[1_000, 600_000]`), and
  `stopped_row_ttl_ms: integer()` (default `86_400_000`, range
  `[60_000, 31_536_000_000]`).

The keys `:marker_path`, `:replay_timeout_ms`, and `:recovery_timeout_ms` no longer
drive anything and are **deprecated**. Supplying any of them SHALL log a WARN naming
the key and SHALL otherwise be ignored, so a deployment carrying them keeps starting.
They SHALL be rejected at init in a future release.

The field SHALL be ignored by the coordinator if its value is anything other than the
documented shapes; an INVALID-config WARN log SHALL fire and the coordinator SHALL
behave as if `auto_recovery == false`.

#### Scenario: Default config — no reconcile, no durable read

- **GIVEN** a hub started with `auto_recovery: false` (or unset)
- **WHEN** the coordinator initialises with `registry_backend: {:dets, []}` and 3
  persisted rows
- **THEN** the in-memory registry does not load those 3 rows
- **AND** `recovery_state` is `:normal` from the moment `init/1` returns
- **AND** no reconcile round runs

#### Scenario: Custom grace, interval, and stopped-row TTL

- **GIVEN** `auto_recovery: [reconcile_grace_ms: 60_000, reconcile_interval_ms: 30_000,
  stopped_row_ttl_ms: 604_800_000]`
- **WHEN** the coordinator initialises
- **THEN** the first round runs no earlier than 60 s after start, subsequent rounds no
  more often than every 30 s, and stopped rows expire 7 days after `stopped_at`

#### Scenario: Deprecated key warns and is ignored

- **GIVEN** `auto_recovery: [marker_path: "/srv/hub/cluster.healthy"]`
- **WHEN** the coordinator initialises
- **THEN** the hub starts with the default reconcile settings
- **AND** a WARN log identifies `:marker_path` as deprecated and names the release
  that removes it

#### Scenario: Out-of-range reconcile_grace_ms rejected

- **GIVEN** `auto_recovery: [reconcile_grace_ms: 100]` (below the `1_000` minimum)
- **WHEN** the coordinator initialises
- **THEN** init fails with
  `{:error, {:invalid_auto_recovery, :reconcile_grace_ms_out_of_range}}`

### Requirement: Hook points for downstream integration

Three hook keys SHALL be available via `ProcessHub.Constant.Hook`:

- `Hook.recovery_state_changed()` — fires on every `recovery_state` transition.
  Payload: `%{from: state, to: state, reason: atom}`. The only transition is
  `:recovering → :normal` with reason `:reconcile_complete`. Async.
- `Hook.pre_recovery_replay()` — fires once, before the **first** reconcile round of a
  coordinator's lifetime issues any start. Synchronous (blocking) — the coordinator
  awaits each handler's reply before proceeding, with the per-handler budget bounded by
  `reconcile_interval_ms`. Use case: downstream users ensure prerequisite services are
  ready before children are started.
- `Hook.post_recovery_replay()` — fires once, after the first reconcile round completes
  (whether or not it started anything). Async.

The hook keys and their synchronous/async contracts are unchanged from the previous
version; only the moment they bracket has changed, from the boot replay to the first
reconcile round. Handlers registered by existing downstream code continue to work
without modification. Handlers for these hooks are not invoked when
`auto_recovery == false`.

Subsequent reconcile rounds SHALL NOT re-fire these hooks; they are boot-integration
points, not per-round hooks. Per-round observability is the `:reconcile` telemetry.

#### Scenario: pre_recovery_replay handler blocks the first round's starts

- **GIVEN** a downstream application registers a `pre_recovery_replay` handler that
  waits until its own service reports ready
- **WHEN** the first reconcile round is due
- **THEN** the coordinator dispatches the hook synchronously
- **AND** no child is started until the handler returns

#### Scenario: Hooks fire once per coordinator lifetime

- **GIVEN** an opt-in hub that has completed 5 reconcile rounds
- **WHEN** the hook dispatch counts are inspected
- **THEN** `pre_recovery_replay` and `post_recovery_replay` have each fired exactly once

### Requirement: Public API for recovery-state introspection

`ProcessHub` SHALL expose:

- `ProcessHub.recovery_state(hub_id) :: :recovering | :normal` — synchronous query of
  the current state. For hubs with `auto_recovery: false`, ALWAYS returns `:normal`.
- `ProcessHub.await_normal(hub_id, timeout_ms \\ 60_000) :: :ok | {:error, :timeout}` —
  blocks until the hub's `recovery_state` is `:normal` or the timeout elapses. For hubs
  with `auto_recovery: false`, returns `:ok` immediately.

Both signatures are unchanged. `:recovery_pending` is no longer a possible return
value. `await_normal/2` now means "the first reconcile round has completed", which is
the point at which a returning node has restored whatever it was going to restore.

Callers SHOULD size their timeout above `reconcile_grace_ms`; a timeout below the grace
window will always return `{:error, :timeout}` on an opt-in hub.

#### Scenario: recovery_state returns :normal for non-opted-in hub

- **GIVEN** a hub started with default config
- **WHEN** `ProcessHub.recovery_state(:my_hub)` is called at any point after `init/1`
- **THEN** it returns `:normal`

#### Scenario: await_normal returns after the first round

- **GIVEN** an opt-in hub with `reconcile_grace_ms: 5_000`
- **WHEN** a caller invokes `ProcessHub.await_normal(:my_hub, 30_000)` at `t = 0`
- **THEN** the call blocks until the first reconcile round completes and returns `:ok`

#### Scenario: Timeout below the grace window always times out

- **GIVEN** an opt-in hub with `reconcile_grace_ms: 30_000`
- **WHEN** `ProcessHub.await_normal(:my_hub, 5_000)` is called at boot
- **THEN** the call returns `{:error, :timeout}`
- **AND** the coordinator continues toward `:normal` independently

### Requirement: Backward compatibility — existing applications need no changes

Applications that never set `:auto_recovery` SHALL require no code, configuration, or
dependency modification. Applications that opted into `auto_recovery` SHALL require the
migration described below — for them this change is breaking.

Preserved unconditionally:

- `auto_recovery: false` (the default) behaves exactly as before: no marker IO existed
  for these hubs, no reconcile runs, `recovery_state` is `:normal` from init, and the
  durable backend is opened without replay.
- `start_link/1`, `child_spec/1`, `is_alive?/1`, `start_children/3`, `stop_children/3`,
  `recovery_state/1`, and `await_normal/2` keep their signatures.
- The `pre_recovery_replay`, `post_recovery_replay`, and `recovery_state_changed` hook
  keys and their blocking/async contracts are unchanged.
- No new required dependencies.

Deprecated for opted-in applications — still compiles and starts, warns, removed in
a future release:

- `ProcessHub.Service.Recovery.prepare_recovery/1` and `prepare_recovery_cluster/1`
  SHALL remain callable as no-ops returning their documented shapes, logging a WARN.
- `:marker_path`, `:replay_timeout_ms`, and `:recovery_timeout_ms` SHALL be accepted
  with a WARN and ignored.

Behaviour that changes for opted-in applications:

- `PROCESS_HUB_RECOVERY_MODE` is no longer read.
- `:recovery_pending` is no longer a `recovery_state/1` return value.
- `[:process_hub, :recovery, :skipped]` and `[:process_hub, :recovery, :timeout]` are no
  longer emitted.

The change SHALL ship as a minor version bump with a `migration-guide.md` section
covering each deprecation and removal, and its replacement.

#### Scenario: Deprecated operator API stays callable

- **GIVEN** an application still calling `Recovery.prepare_recovery_cluster/1` on a
  running hub
- **WHEN** the call runs
- **THEN** it returns `{:ok, members}` and logs a deprecation WARN
- **AND** no marker file is read or written

#### Scenario: Pre-change default-config test suite passes unchanged

- **GIVEN** an existing single-node test that uses `auto_recovery: false` (default) and
  `registry_backend: {:dets, []}`
- **WHEN** the suite runs against post-change ProcessHub
- **THEN** all tests pass with no modifications

#### Scenario: Opted-in application with a removed key fails fast

- **GIVEN** an application upgrading with `auto_recovery: [marker_path: "..."]` in place
- **WHEN** the hub starts
- **THEN** init fails with a message naming `:marker_path` and pointing at the
  migration guide, rather than starting with silently different behaviour

### Requirement: Fast-restart purge signal within :net_ticktime

The coordinator SHALL broadcast a `{:cluster_join, {:restarted, node()}}` fast-restart purge signal to every reachable peer hub on entering `:normal` (recovery completed OR normal-mode boot), provided the hub detects it is rejoining a cluster where peers may still be holding bindings whose pid lives on `node()` (the previous incarnation).

On receipt of `{:cluster_join, {:restarted, restarted_node}}`, peers SHALL
preemptively purge from their in-memory registry any binding whose `node_pids`
list contains `restarted_node`, **before** the existing `init_sync` flow runs.

This closes the "ghost pid" window when a pod restarts faster than peers detect
the disconnect (i.e. within `:net_ticktime`). Peers running older ProcessHub
versions SHALL silently drop the signal (graceful degradation in mixed-version
clusters — the same pattern ProcessHub uses for other additive cluster events).

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

ProcessHub SHALL emit `[:telemetry]`-compatible events for the boot lifecycle:

- `[:process_hub, :recovery, :started]` — emitted once when the first reconcile round
  begins. Measurements: `%{candidate_count: N, system_time: t}`. Metadata: `%{hub_id}`.
- `[:process_hub, :recovery, :complete]` — emitted once when the first reconcile round
  completes and the coordinator transitions to `:normal`. Measurements:
  `%{candidate_count, orphans, started, duplicates, elapsed_ms}`. Metadata: `%{hub_id}`.

`[:process_hub, :recovery, :skipped]` and `[:process_hub, :recovery, :timeout]` are
removed: the first names a marker-present boot that no longer exists, the second a
replay ceiling that no longer exists. Per-round observability is
`[:process_hub, :reconcile, :round]`, specified in `registry-convergence`.

#### Scenario: Opt-in boot emits started then complete

- **GIVEN** an opt-in hub with 3 durable candidates and an empty cluster
- **WHEN** the first reconcile round runs
- **THEN** exactly one `:started` event with `candidate_count: 3` and one `:complete`
  event with `started: 3` are emitted, in that order

#### Scenario: Non-opted-in hub emits neither

- **GIVEN** a hub with `auto_recovery: false`
- **WHEN** it boots and runs
- **THEN** no `[:process_hub, :recovery, _]` event is emitted

