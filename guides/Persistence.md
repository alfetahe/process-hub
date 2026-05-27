# Persistence

By default ProcessHub keeps its per-coordinator process registry in an
in-memory ETS table. When the coordinator restarts, the registry is
rebuilt from peers via the configured synchronization strategy. A node
that returns into a cluster of `:bootstrap`-state peers, or restarts as
a sole survivor, has no record of the children it was hosting.

For workloads that need restart-survival on a single node, ProcessHub
supports an opt-in **DETS**-backed registry. This is configured via the
`:registry_backend` field on `%ProcessHub{}`.

## Backends

`:registry_backend` accepts these shapes:

- `:ets` — *(default)* in-memory ETS. Identical to all prior behaviour.
  Existing applications need no changes.
- `{:dets, opts}` — on-disk persistence via `:dets`. Recognised opts:
  - `path: String.t()` — file path. Defaults to
    `priv/process_hub/<hub_id>/registry.dets`.
- `{Module, opts}` — a custom module implementing
  `ProcessHub.Service.Storage.Behaviour`. Useful for an in-memory test
  backend or any external store you want to plug in.

```elixir
ProcessHub.child_spec(%ProcessHub{
  hub_id: :my_hub,
  registry_backend: {:dets, path: "/var/lib/myapp/hub.dets"}
})
```

## Recovery semantics on corruption

The DETS backend opens its file with `repair: true`. If
`:dets.open_file/2` still returns `{:error, _}` (unrecoverable
corruption), the file is rotated:

- The corrupt file is renamed to `<path>.corrupt-<system_monotonic>`.
- A `[:process_hub, :registry, :backend_corrupt]` telemetry event is
  emitted with `%{path: <orig>, rotated_to: <rotated>, reason: term}`.
- A fresh empty DETS file is opened at the original path. The hub
  starts with an empty local registry; cluster-wide state is rebuilt
  via the synchronization strategy.

This matches the operational pattern of refusing to fail-stop on
corruption: the system continues to run, the corrupt artefact is
preserved for forensics, and an alerting hook can listen on the
telemetry event.

## Telemetry events

The DETS backend emits the following events:

- `[:process_hub, :registry, :backend_opened]` —
  `%{row_count: N, elapsed_ms: T}` /
  `%{hub_id, backend, path, repaired: bool}`. Fired once per hub start.
- `[:process_hub, :registry, :backend_corrupt]` (DETS only) — fired
  when the file was rotated.
- `[:process_hub, :registry, :insert]` — `%{count: 1}` /
  `%{hub_id, child_id}`. Fired on every successful insert.
- `[:process_hub, :registry, :remove]` — `%{count: 1}` /
  `%{hub_id, child_id}`. Fired on every successful remove.

The default ETS backend does NOT emit these events (zero-cost path).

## Operational profile

Each registry mutation calls `:dets.sync/1` before returning. This
guarantees that any operation observed as `:ok` is durable on disk. On
local SSD this typically adds ~1–5 ms of latency per write; on slower
disks it can be more. Workloads with very high registry mutation rates
should keep the default `:ets` backend.

DETS does not compact automatically — deleted entries leave gaps in
the file. The registry is bounded by the number of children, so this
is usually negligible. Periodic compaction via `:dets.repair/1` is an
operator concern.

## TTL semantics

DETS has no native TTL. Entries inserted with a `:ttl` are stored as
`{key, value, expire_ms}` (matching the ETS layout). Reads filter
expired entries on the way out. A periodic sweeper for expired
entries is out of scope; expired rows accumulate until manually swept.
TTL usage on the registry is rare and bounded.

## Custom backends

Implement `ProcessHub.Service.Storage.Behaviour` and pass
`registry_backend: {MyModule, opts}`. Backends that may fail
synchronously (timeout, no quorum, IO error) can return
`{:error, reason}` from any mutating callback — the API is shaped so
that a future replicated backend (Raft, etc.) can plug in without
breaking existing call sites.

## Coordinator recovery

When a returning node holds a persisted registry, naively re-asserting
those rows on boot would either resurrect children the cluster has
already redistributed or duplicate children running on peers. The
opt-in **coordinator recovery** lifecycle gives the coordinator a
"wait and see" phase so it can defer to peers when they hold
authoritative state.

### The three states

The coordinator's `:recovery_state` is one of:

  * **`:recovery_pending`** — initial state when `:auto_recovery` is
    enabled. The coordinator is gathering peer information to decide
    whether to replay locally.
  * **`:recovering`** — actively iterating the persisted registry and
    dispatching `start_children` calls.
  * **`:normal`** — fully operational. Reachable from
    `:recovery_pending` (deferred-to-peers path) or from `:recovering`
    (replay completed or timed out).

When `:auto_recovery` is `false` (the default), `:recovery_state` is
`:normal` from `init/1` and never transitions — preserving every bit
of pre-existing behaviour.

### Configuration

```elixir
%ProcessHub{
  hub_id: :my_hub,
  registry_backend: {:dets, []},
  auto_recovery: [
    recovery_window_ms: 10_000,
    replay_timeout_ms: 60_000
  ]
}
```

Accepted shapes:

  * `false` (default) — disabled.
  * `true` — enabled with default window and timeout.
  * `keyword()` — explicit:
    * `:recovery_window_ms` — default `10_000`, range
      `[1_000, 600_000]`.
    * `:replay_timeout_ms` — default `60_000`, range
      `[1_000, 3_600_000]`.

Out-of-range values cause the coordinator to refuse to start with
`{:invalid_auto_recovery, _}`.

### Peer handshake

While in `:recovery_pending`, on receipt of `@event_cluster_join` for a
new peer, the coordinator dispatches `@event_recovery_state_query` to
that peer. The peer responds with `@event_recovery_state_announce`
carrying its current state.

  * If any peer reports `:normal`, the coordinator cancels the window
    timer and transitions directly to `:normal` (skip replay; the
    existing synchronization strategy populates the local registry
    from peers).
  * If the window elapses without a `:normal` peer, the coordinator
    transitions to `:recovering`, replays its persisted registry via
    `Distributor.compose_start_operation/3`, then transitions to
    `:normal`.

Old ProcessHub versions silently drop the new events (no handler
registered) — mixed-version clusters function correctly.

### Hooks

Three new hooks (see `ProcessHub.Constant.Hook`) cover the lifecycle:

  * `recovery_state_changed/0` — fires on every transition (async).
    Payload: `%{from: state, to: state, reason: atom(),
    peers: %{node => state}}`.
  * `pre_recovery_replay/0` — fires once when entering `:recovering`,
    before any `start_children` is dispatched. **Synchronous** — the
    coordinator awaits each handler's reply. Use for prerequisite
    services (e.g. wait until a downstream FleetManager is ready).
    Handlers are wrapped in `try/catch` with a per-handler timeout
    derived from `:replay_timeout_ms`; crashes are logged and the
    lifecycle proceeds.
  * `post_recovery_replay/0` — fires once when leaving `:recovering`
    (async). Use to mark "boot complete."

### Public API

```elixir
ProcessHub.recovery_state(:my_hub)
# => :recovery_pending | :recovering | :normal

ProcessHub.await_normal(:my_hub, 30_000)
# => :ok | {:error, :timeout}
```

For hubs without `:auto_recovery`, both functions report `:normal` /
`:ok` immediately.

### Telemetry

Two events are emitted from the replay path:

  * `[:process_hub, :coordinator, :recovery_replay_started]`
    — measurements `%{child_count: N}`, metadata `%{hub_id: id}`.
  * `[:process_hub, :coordinator, :recovery_replay_completed]`
    — measurements `%{child_count: N, succeeded: S, failed: F,
    elapsed_ms: T}`, metadata `%{hub_id: id, reason: atom()}`. The
    `reason` is `:completed`, `:replay_timeout`, or `:empty`.

### Recommended pairing

`auto_recovery: true` is most useful with a persistent registry
backend such as `registry_backend: {:dets, []}` or
`{:durable_ets, []}`. With the default `:ets` backend, the registry
is empty on every restart — the coordinator transitions through
`:recovering` with zero rows to replay and immediately reaches
`:normal`. The combination is permitted but does not provide
restart-survival; documentation calls this out so operators do not
assume otherwise.

## Operator-controlled recovery via marker file

The peer-handshake protocol above defers to peers on a per-event
basis: a returning node asks each joining peer whether the peer is
already `:normal`, and only replays from disk when no peer says yes
inside the window. That works for the "we lost a single node and
peers are healthy" case — but it does not catch the **DETS-read on
open** path that runs *before* any peer can be consulted.

The defect in the open-time replay is that:

1. `Storage.Dets.open/2` and `Storage.DurableEts.open/2` populate the
   in-memory registry from DETS at boot.
2. A single node returning to a multi-node cluster therefore re-asserts
   its **stale** local rows (dead pids, obsolete metadata) into the
   in-memory view.
3. The peer handshake happens too late — `init_sync` then merges the
   polluted local view back into the cluster, leaving every peer with
   ghost bindings whose pid lives on the rejoining node but does not
   actually exist there.

The opt-in **marker file gate** fixes this by making the operator
the source of truth for "should this node trust its local DETS?"
A per-node zero-byte marker file is consulted at `init/1` — *before*
the backend opens — and the resolved decision is passed straight
through to the backend `open/2` call.

### Mode resolution

The recovery mode resolves at coordinator `init/1` from three inputs,
in precedence order:

1. **`PROCESS_HUB_RECOVERY_MODE`** env var, when set:
   * `force` — recover even if the marker is present.
   * `skip` — never recover even if the marker is absent (start
     empty; do not read DETS; still write the marker on entry to
     `:normal`).
   * `auto` (default if unset) — fall through to the marker decision.
2. **`:recovery_marker.enabled?`** is `false` → mode is `:normal`
   (this is the opt-out for consumers that want to keep using the
   legacy peer-mode-exchange path).
3. **Marker file present** at the resolved path → mode is `:normal`;
   **absent** → mode is `:recovery`.

Unknown env values fall back to `auto` and emit a WARN log naming
the offending value. The env var is evaluated **once** at
`init/1` — runtime changes do not affect an already-resolved mode.

### Configuration

```elixir
%ProcessHub{
  hub_id: :my_hub,
  registry_backend: {:durable_ets, []},
  auto_recovery: [
    recovery_window_ms: 10_000,
    replay_timeout_ms: 60_000,
    recovery_timeout_ms: 30_000
  ],
  recovery_marker: %{
    enabled?: true,
    path: "/var/lib/process_hub/my_hub/cluster.healthy"
  }
}
```

`:recovery_marker` accepts `%{enabled?: boolean(), path: nil | String.t()}`:

* `enabled?` — defaults to `auto_recovery != false`. When `false`,
  the marker gate is bypassed entirely and the legacy peer-mode-
  exchange protocol drives the lifecycle (no DETS-read gating, no
  marker IO).
* `path` — when `nil`, resolves to
  `:filename.basedir(:user_data, "process_hub")/<hub_id>/cluster.healthy`
  (typically `/var/lib/process_hub/<hub_id>/cluster.healthy` on
  Linux). The parent directory is created on first write.

`:recovery_timeout_ms` (new, inside `:auto_recovery`) is the upper
bound on the cluster-event **queue gate**. Default `30_000`, range
`[1_000, 600_000]`. The previous `:replay_timeout_ms` keeps its
meaning as the upper bound on the replay loop itself; both timers
race and the earlier of the two opens the gate.

### Boot sequences

**Normal-mode boot (marker present, env=auto)**

1. Resolve mode → `:normal`.
2. Open the backend with `recovery_replay: false` — DETS opened but
   no row is loaded into the in-memory view.
3. `:recovery_state` is `:normal` from `init/1`.
4. Emit `[:process_hub, :recovery, :skipped]` with
   `reason: :marker_present`.
5. (Re)write the marker (idempotent).
6. Register cluster handlers — no queue, no waiting.
7. First `@event_cluster_join` → existing `NodeUp.handle/1` runs and
   `init_sync` inherits state from peers.

**Recovery-mode boot (marker absent, env=auto)**

1. Resolve mode → `:recovery`.
2. Open the backend with `recovery_replay: true` — DETS rows are
   loaded into the in-memory view (cspecs only).
3. `:recovery_state` is `:recovery_pending`.
4. Emit `[:process_hub, :recovery, :started]` with `cspec_count`.
5. Schedule the `recovery_timeout_ms` ceiling timer.
6. Spawn the replay task: for each cspec, dispatch
   `Distributor.compose_start_operation/3` with cspec-only payload.
   Per-cspec failures log WARN and increment the `failed` counter
   without aborting the loop.
7. While in `:recovery_pending` / `:recovering`, the coordinator
   **queues** incoming cluster events (`@event_cluster_join`,
   `@event_cluster_leave`, `:nodedown`) in `state.recovery_event_queue`
   instead of processing them inline. BEAM distribution itself keeps
   running normally — only ProcessHub's handlers are gated.
8. When every cspec has been attempted (success / error / skip), or
   the `recovery_timeout_ms` ceiling fires, the gate opens:
   * Cancel the timeout timer.
   * Emit `[:process_hub, :recovery, :complete]` or `:timeout`.
   * Dispatch `recovery_state_changed` (`:recovering → :normal`).
   * Write the marker.
   * Broadcast `{:cluster_join, {:restarted, node()}}` to peers
     (fast-restart purge signal — see below).
   * Drain the event queue in FIFO order through the normal handlers.
9. Subsequent cluster events are processed inline.

### Cspecs-only replay

Recovery replay loads `child_spec` only — `node_pids` and metadata
are **dropped**. Bindings (assigned executor, last-seen pid,
downstream-consumer metadata) are recomputed by the first migration
tick after the cluster forms. This is the change that closes the
stale-binding leak: a recovered row routes through exactly the same
code as a freshly-registered, never-yet-started child
(`Extractor.local_and_empty_children/1`).

### Operator API

```elixir
# Arm the local node for recovery on next boot.
ProcessHub.prepare_recovery(:my_hub)
# => :ok | {:error, term()}

# Arm every hub member via :rpc.multicall/4.
ProcessHub.prepare_recovery_cluster(:my_hub)
# => {:ok, [node()]}
# | {:partial, [acked :: node()], [unreachable :: node()]}
# | {:error, term()}
```

Both functions only delete the marker file; the running coordinator
is **not** interrupted. The next coordinator boot picks up the marker
absence. Hubs whose `:recovery_marker.enabled?` is `false` ignore the
call and return `:ok`.

Wrap `prepare_recovery_cluster/1` in your operations CLI when you
plan a full-cluster restart — it is the runbook step that distin-
guishes "rolling restart, peers dominate" from "drain & rebuild from
disk".

### Fast-restart purge signal

When a pod restarts faster than peers detect the disconnect (i.e.
within `:net_ticktime`), peers may still be holding bindings whose
`node_pids` lists contain `{restarted_node, dead_pid}`. The
coordinator emits a tagged variant of `@event_cluster_join` —
`{:cluster_join, {:restarted, node()}}` — exactly once per lifetime
on entry to `:normal`. Peers route the tagged variant through
`ProcessHub.Service.ProcessRegistry.purge_node_bindings/2`, which
drops the restarted node from every binding's `node_pids` list
(deleting the binding when the list becomes empty). The subsequent
`init_sync` then runs against a clean peer view.

Old ProcessHub peers silently drop the tagged variant — same mixed-
version graceful-degradation pattern as the existing
`@event_recovery_state_announce` handling.

### Telemetry

The marker-gated path emits four `[:process_hub, :recovery, _]`
events (additive — independent of the legacy
`[:process_hub, :coordinator, :recovery_replay_*]` events):

* `[:process_hub, :recovery, :started]` —
  `%{cspec_count, system_time}` /
  `%{hub_id, mode, marker_path}`.
* `[:process_hub, :recovery, :complete]` —
  `%{cspec_count, succeeded, failed, skipped, elapsed_ms}` /
  `%{hub_id, mode}`.
* `[:process_hub, :recovery, :skipped]` — `%{system_time}` /
  `%{hub_id, reason}` where `reason ∈ {:marker_present, :env_skip,
  :disabled}`.
* `[:process_hub, :recovery, :timeout]` —
  `%{cspec_count, attempted, elapsed_ms}` / `%{hub_id, mode}`.

Operators running dashboards typically alert on `:skipped` being the
steady state (green) and on unexpected `:started` / `:timeout` events
(amber / red).

The `[:process_hub, :registry, :backend_opened]` event now also
carries `replayed: boolean()` in metadata, distinguishing normal-mode
(no replay) from recovery-mode (full replay) boots.

### Failure modes

* **Corrupt DETS in recovery mode.** The backend rotates the corrupt
  file to `<path>.corrupt-<monotonic>` and opens a fresh empty file.
  Recovery runs against an empty registry, emits `:complete` with
  `cspec_count: 0`, writes the marker, and transitions to `:normal`.
  The operator gets a loud telemetry signal that recovery ran against
  an empty file.
* **Marker write failure (e.g. disk full).** Logged at ERROR; the
  coordinator continues with `recovery_state: :normal`. The next boot
  sees the marker absent and selects recovery mode again — fail-safe
  default ("a node that cannot persist 'I am healthy' must default to
  'I might not be healthy'").
* **`prepare_recovery_cluster` partial reach.** Returns
  `{:partial, acked, unreachable}` — operators handle by retrying or
  by arming the down nodes manually before they boot.
* **Operator armed recovery mid-recovery.** Calling
  `prepare_recovery/1` while the coordinator is in `:recovering`
  deletes the marker, but the in-flight replay still completes and
  the marker is rewritten on transition to `:normal`. Re-arm by
  calling `prepare_recovery/1` *after* the coordinator reaches
  `:normal` (use `await_normal/2` to wait).
* **Cluster-wide cold boot stampede.** If every node's marker is
  absent simultaneously (e.g. a power-cycle that hits every pod), the
  full cluster recovers from disk in parallel. This is the intended
  "drain & rebuild from disk" path. To avoid it on a *planned* full
  restart, **do not** arm `prepare_recovery_cluster/1` for that
  operation — let the markers stay present and rely on peers.
  Cluster-wide cold boot is what `prepare_recovery_cluster/1` is
  *for*; do not invoke it casually.
* **Ephemeral / `emptyDir`-style storage.** The marker path and the
  DETS path must live on the same persistent volume. The defaults
  (`/var/lib/process_hub/<hub_id>/cluster.healthy` and
  `priv/process_hub/<hub_id>/registry.dets`) assume persistent
  storage; operators using ephemeral pod storage already cannot use
  the persistent backends for restart-survival anyway.

### Choosing between the two recovery paths

| Concern | `recovery_marker: %{enabled?: true}` (default) | `recovery_marker: %{enabled?: false}` (opt-out) |
| --- | --- | --- |
| Mode selector | env > marker > config | peer-mode-exchange (legacy) |
| DETS read on open | gated by mode | always replayed |
| Cluster-event queue | active in `:recovering` | not used |
| Operator action to recover | `prepare_recovery_cluster/1` before restart | none — peer handshake decides per node |
| Fast-restart purge signal | emitted | emitted (when `auto_recovery: true`) |
| Stale-binding leak window | closed | open (the bug this change fixes) |

New deployments should prefer the marker-gated path. Existing
consumers that rely on the peer-mode-exchange semantics can opt out
explicitly by setting `recovery_marker: %{enabled?: false}` and
otherwise leaving `:auto_recovery` unchanged.

## Hybrid backend (`:durable_ets`)

The `{:durable_ets, opts}` backend keeps an in-memory ETS table as the
source-of-truth for both reads and writes, and mirrors every mutation
synchronously to a DETS file for restart-survival. On open, the DETS
file is replayed into ETS so reads are immediately authoritative.

```elixir
%ProcessHub{
  hub_id: :my_hub,
  registry_backend: {:durable_ets, path: "/var/lib/myapp/hub.dets"}
}
```

`:path` defaults to `priv/process_hub/<hub_id>/registry.dets` — the
same default as `{:dets, _}`. The file format on disk is a plain DETS
file, so an operator can switch a hub between `{:dets, _}` and
`{:durable_ets, _}` against the same path and pick up the existing
rows.

### Read path

`get/2`, `exists?/2`, `foldl/3`, `match/2`, and `export_all/1` dispatch
exclusively to the ETS table — equivalent to the in-memory `:ets`
backend. Hot-path callers (`ProcessHub.child_lookup/2`,
`process_list/2`, the `start_children` `check_existing` lookup, etc.)
do not pay the DETS read cost.

### Write path

`insert/3`, `insert/4`, `remove/2`, and `clear_all/1` write to ETS
first, then DETS, then call `:dets.sync/1` before returning. Once
`:ok` is observed by the caller, the row is durable on disk —
identical to the `{:dets, _}` backend's contract.

If the DETS write fails (e.g. the underlying volume becomes
read-only), the in-memory ETS write is rolled back so observers see
consistent state and the call returns `{:error, reason}`.

### Crash semantics

Between the ETS write and the `:dets.sync/1` return, a row is in
memory but not yet durable. On restart, ETS is rebuilt from DETS — an
inflight write is lost. Identical to the `{:dets, _}` backend's
existing crash window.

### Telemetry

The same events as the `{:dets, _}` backend, with the `:backend`
metadata set to `ProcessHub.Service.Storage.DurableEts`:

  * `[:process_hub, :registry, :backend_opened]`
  * `[:process_hub, :registry, :backend_corrupt]`
  * `[:process_hub, :registry, :insert]`
  * `[:process_hub, :registry, :remove]`

Dashboards built for the `{:dets, _}` backend continue to work; filter
by the `:backend` metadata field if you want to distinguish the two.

### Trade-offs

| Concern | `:ets` | `{:dets, _}` | `{:durable_ets, _}` |
| --- | --- | --- | --- |
| Read latency | ETS | DETS (slower) | ETS |
| Write latency | ETS | DETS + `fsync` | ETS + DETS + `fsync` |
| Restart-survival | no | yes | yes |
| RAM footprint | rows in RAM | metadata only | rows in RAM |
| Disk footprint | none | rows on disk | rows on disk |

Pick `{:durable_ets, _}` when reads dominate the workload and
restart-survival matters. Pick `{:dets, _}` when writes dominate and
RAM is constrained. Pick `:ets` when neither restart-survival nor
disk durability is required.
