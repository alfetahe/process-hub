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
round opens on peer evidence, and `reconcile_grace_ms` caps the wait, so `:normal` is
reached in bounded time on every boot, including a single node booting alone and
including a node whose peer is connected but never answers.

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
- **WHEN** the cluster settle window elapses with no peer connected
- **THEN** the first round runs against an empty cluster view and the coordinator
  transitions to `:normal`, without waiting for `reconcile_grace_ms`

### Requirement: `:auto_recovery` configuration field

`ProcessHub.t()` SHALL include the optional field `:auto_recovery` as the single
configuration entry point for registry convergence and orphan recovery, accepting:

- `false` — default. No reconcile rounds, no epoch stamping beyond what a single node
  writes locally, `recovery_state` is `:normal` from init. Library tests and
  single-node deployments are unaffected.
- `true` — enable with defaults.
- `keyword()` — accepts
  `reconcile_grace_ms: integer()` (default `30_000`, range `[50, 600_000]`), the cap on
  the wait for the first reconcile round;
  `cluster_settle_ms: integer()` (default `2_000`, range `[0, 60_000]`);
  `reconcile_interval_ms: integer()` (default `15_000`, range `[1_000, 600_000]`); and
  `remote_manifest`, specified by the `remote-manifest` capability.

The keys `:marker_path`, `:replay_timeout_ms`, `:recovery_timeout_ms`, and
`:stopped_row_ttl_ms` no longer drive anything and are **deprecated**. Supplying any of
them SHALL log a WARN naming the key and SHALL otherwise be ignored, so a deployment
carrying them keeps starting. They SHALL be rejected at init in a future release.

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

#### Scenario: Custom grace and interval

- **GIVEN** `auto_recovery: [reconcile_grace_ms: 60_000, reconcile_interval_ms: 30_000]`
- **WHEN** the coordinator initialises
- **THEN** the first round runs no later than 60 s after start, and subsequent rounds no
  more often than every 30 s

#### Scenario: Deprecated key warns and is ignored

- **GIVEN** `auto_recovery: [marker_path: "/srv/hub/cluster.healthy"]`
- **WHEN** the coordinator initialises
- **THEN** the hub starts with the default reconcile settings
- **AND** a WARN log identifies `:marker_path` as deprecated and names the release
  that removes it

#### Scenario: Out-of-range reconcile_grace_ms rejected

- **GIVEN** `auto_recovery: [reconcile_grace_ms: 49]` (below the `50` minimum)
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

The first round usually opens well before `reconcile_grace_ms`, but the grace is the
only bound that holds on every boot, so callers that must not time out SHOULD size their
timeout above it.

#### Scenario: recovery_state returns :normal for non-opted-in hub

- **GIVEN** a hub started with default config
- **WHEN** `ProcessHub.recovery_state(:my_hub)` is called at any point after `init/1`
- **THEN** it returns `:normal`

#### Scenario: await_normal returns after the first round

- **GIVEN** an opt-in hub with `reconcile_grace_ms: 5_000`
- **WHEN** a caller invokes `ProcessHub.await_normal(:my_hub, 30_000)` at `t = 0`
- **THEN** the call blocks until the first reconcile round completes and returns `:ok`

#### Scenario: Timeout below the time to the first round times out

- **GIVEN** an opt-in hub whose first reconcile round has not yet completed
- **WHEN** `ProcessHub.await_normal(:my_hub, 200)` is called at boot and the round does
  not complete within 200 ms
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

### Requirement: The first reconcile round opens on peer evidence

The first reconcile round SHALL open at the first moment at which both of these hold:
the cluster settle window has elapsed since coordinator start, and every connected peer
the hub knows about has delivered its registry data. `reconcile_grace_ms` SHALL open the
round unconditionally when it elapses, so a connected peer that never answers cannot hold
a hub in `:recovering` indefinitely.

A peer's registry data counts as delivered when the coordinator has handled that node's
registry broadcast. The record SHALL be kept by the coordinator rather than by a
synchronization strategy, so every strategy, including a custom one, satisfies the gate
the same way.

`reconcile_grace_ms` SHALL act as a maximum and never as a minimum: when it is shorter
than the cluster settle window, it opens the round and the settle window has no effect.
A hub configured with a short grace therefore keeps its current timing.

`Recovery.round_due?/2` SHALL be the single answer to whether a round may run, for the
first round as well as later ones, and SHALL take the trigger asking for it — a completed
synchronisation round, first-round evidence, or the grace cap. It SHALL NOT refuse a round
solely because `recovery_state` is `:recovering`; the evidence gate decides instead, while
the overlap guard and the `reconcile_interval_ms` rate limit continue to apply unchanged.

The coordinator SHALL announce its presence to the cluster at the end of `init/1`, in
addition to the announcement scheduled at `hubs_discover_interval`, so a peer answers and
its registry data arrives without waiting for the first discovery tick.

`ProcessHub.Initializer` SHALL NOT warn about `reconcile_grace_ms` being at or below
`sync_interval`. The first round no longer depends on the periodic synchronisation having
run, so the relationship that warning described no longer exists.

#### Scenario: A node with no peers opens the round after the settle window

- **GIVEN** an opt-in hub with `cluster_settle_ms: 2_000` and `reconcile_grace_ms: 45_000`
- **AND** no peer is connected at any point
- **WHEN** 2 000 ms have elapsed since coordinator start
- **THEN** the first reconcile round runs and `recovery_state` becomes `:normal`
- **AND** it does so without waiting for `reconcile_grace_ms`

#### Scenario: A peer's registry data opens the round

- **GIVEN** an opt-in hub with `cluster_settle_ms: 2_000` and `reconcile_grace_ms: 45_000`
- **AND** one connected peer running the same hub
- **WHEN** the peer's registry broadcast has been handled and the settle window has
  elapsed
- **THEN** the first reconcile round runs against a cluster view that includes the peer's
  rows, well before `reconcile_grace_ms` elapses

#### Scenario: A connected peer that never answers is capped by the grace

- **GIVEN** an opt-in hub with `reconcile_grace_ms: 45_000` and one connected peer whose
  hub never delivers registry data
- **WHEN** 45 000 ms have elapsed since coordinator start
- **THEN** the first reconcile round runs anyway and `recovery_state` becomes `:normal`

#### Scenario: A grace shorter than the settle window wins

- **GIVEN** an opt-in hub with `reconcile_grace_ms: 100` and the default
  `cluster_settle_ms`
- **WHEN** the coordinator initialises
- **THEN** the first reconcile round runs at 100 ms, exactly as it did before this change

### Requirement: `cluster_settle_ms` configuration key

The `:auto_recovery` keyword configuration SHALL accept `cluster_settle_ms: integer()`
(default `2_000`, range `[0, 60_000]`), which is how long silence from the cluster counts
as "this node is alone" before the first reconcile round may open.

A value outside the range SHALL fail init with
`{:error, {:invalid_auto_recovery, :cluster_settle_ms_out_of_range}}`, consistent with the
other bounded keys. A host that forms its cluster before starting its hubs MAY set `0`.

`ProcessHub.Service.Recovery.parse_config/1` SHALL read the key, so the documented
configuration surface continues to name only keys the library acts on.

#### Scenario: Default settle window

- **GIVEN** `auto_recovery: true`
- **WHEN** the coordinator initialises
- **THEN** the parsed configuration carries `cluster_settle_ms: 2_000`

#### Scenario: Host declares its cluster is already formed

- **GIVEN** `auto_recovery: [cluster_settle_ms: 0]` and no connected peers
- **WHEN** the coordinator initialises
- **THEN** the first reconcile round opens immediately, without a settle wait

#### Scenario: Out-of-range cluster_settle_ms rejected

- **GIVEN** `auto_recovery: [cluster_settle_ms: 120_000]` (above the `60_000` maximum)
- **WHEN** the coordinator initialises
- **THEN** init fails with
  `{:error, {:invalid_auto_recovery, :cluster_settle_ms_out_of_range}}`

