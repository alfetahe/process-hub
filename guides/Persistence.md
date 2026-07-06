# Persistence

By default ProcessHub keeps its per-coordinator process registry in an
in-memory ETS table, rebuilt from peers on restart via the configured
synchronization strategy. A node that restarts as a sole survivor has no
record of the children it was hosting.

For restart-survival on a single node, ProcessHub supports opt-in on-disk
registry backends, configured via the `:registry_backend` field on
`%ProcessHub{}`.

## Backends

`:registry_backend` accepts:

- `:ets` — *(default)* in-memory ETS. Unchanged prior behaviour.
- `{:dets, opts}` — on-disk persistence via `:dets`.
- `{:durable_ets, opts}` — hybrid: ETS for reads, mirrored synchronously
  to DETS for restart-survival (see [Hybrid backend](#hybrid-backend-durable_ets)).
- `{Module, opts}` — a custom module implementing
  `ProcessHub.Service.Storage.Behaviour`.

Both disk backends accept `path: String.t()`, defaulting to
`priv/process_hub/<hub_id>/registry.dets`. They share the same on-disk
format, so a hub can switch between them against the same path.

```elixir
ProcessHub.child_spec(%ProcessHub{
  hub_id: :my_hub,
  registry_backend: {:dets, path: "/var/lib/myapp/hub.dets"}
})
```

## Operational profile

Each DETS mutation calls `:dets.sync/1` before returning, so any operation
observed as `:ok` is durable on disk (~1–5 ms per write on local SSD, more
on slower disks). Workloads with very high registry mutation rates should
keep the default `:ets` backend.

DETS does not compact automatically — deleted entries leave gaps, but the
registry is bounded by child count, so this is usually negligible. Entries
with a `:ttl` are stored as `{key, value, expire_ms}` and filtered on read;
there is no background sweeper for expired rows.

On open the file is opened with `repair: true`. If it is still
unrecoverable, the corrupt file is rotated to
`<path>.corrupt-<system_monotonic>`, an error is logged, and a fresh empty
file is opened — the hub starts empty and rebuilds cluster state from peers
rather than fail-stopping.

## Custom backends

Implement `ProcessHub.Service.Storage.Behaviour` and pass
`registry_backend: {MyModule, opts}`. Mutating callbacks may return
`{:error, reason}`, so a future replicated backend (Raft, etc.) can plug
in without breaking existing call sites.

## Fast-restart stale-binding reaping

If a node restarts within `:net_ticktime`, peers never see a `:nodedown`
and can be left holding registry entries that point at the node's now-dead
pids (the rejoin sync only appends). This is independent of the registry
backend — the stale rows live on the peer.

Every node broadcasts a per-boot token on startup. A peer purges another
node's bindings only when that node's token **changes**, which distinguishes
a genuine restart (new token → reap the dead pids) from a transient network
flap (same token → keep the live bindings). The purged children are then
re-placed by the normal redistribution path. This runs for all backends,
including the default `:ets`, and requires no `:auto_recovery`.

## Observability

ProcessHub reports through its hook system, not telemetry. The recovery
lifecycle is observable via the `recovery_state_changed` hook (see below);
registry-file corruption is logged at ERROR. There are no per-mutation
events on the hot path.

## Coordinator recovery

> #### Experimental {: .warning}
>
> Coordinator recovery (the `:auto_recovery` lifecycle) is **experimental**
> and may change. The persistence backends above are not affected by this
> notice.

Recovery is **operator-controlled**. A returning node only rebuilds from
its local disk when the operator has armed it to; otherwise it trusts its
peers. This prevents a rejoining node from re-asserting stale local rows
(dead pids, obsolete metadata) into a healthy cluster.

The gate is a per-node zero-byte **marker file**, consulted at coordinator
`init/1` before the backend opens:

- **Marker present** → `:normal`. The backend opens without loading any
  rows; the synchronization strategy populates the registry from peers.
- **Marker absent** → `:recovery`. The coordinator replays its persisted
  registry (child specs only), then transitions to `:normal` and writes
  the marker.

A successful boot always writes the marker, so steady-state restarts skip
replay. To arm a node for disk recovery, the operator deletes the marker.

### Recovery states

`:recovery_state` is `:recovering` (replaying from disk) or `:normal`
(operational). With `auto_recovery: false` (the default) it is `:normal`
from `init/1` and never transitions.

### Configuration

```elixir
%ProcessHub{
  hub_id: :my_hub,
  registry_backend: {:dets, []},
  auto_recovery: [
    marker_path: "/var/lib/process_hub/my_hub/cluster.healthy",
    recovery_timeout_ms: 30_000
  ]
}
```

`:auto_recovery` accepts `false` (default), `true` (default path and
timeout), or a keyword list:

- `:marker_path` — override; defaults to
  `:filename.basedir(:user_data, "process_hub")/<hub_id>/cluster.healthy`.
- `:recovery_timeout_ms` — safety ceiling on the `:recovering` state:
  bounds the replay loop and force-opens the cluster-event queue gate.
  Default `30_000`, range `[1_000, 600_000]`.

Out-of-range values fail startup with `{:invalid_auto_recovery, _}`.

### Cspecs-only replay

Replay loads `child_spec` only — `node_pids` and metadata are dropped and
recomputed by the first migration tick, so a recovered row routes through
exactly the same path as a freshly-registered child (this is what closes
the stale-binding leak). While recovering, the coordinator queues incoming
cluster events and drains them FIFO once the gate opens.

Stale bindings for a returning node are reaped separately by the general
per-boot token mechanism (see
[Fast-restart stale-binding reaping](#fast-restart-stale-binding-reaping)),
independent of `:auto_recovery`.

### Hooks

- `recovery_state_changed` — every transition (async); `%{from, to, reason}`.
- `pre_recovery_replay` — once before replay (**synchronous** — the
  coordinator awaits each handler; use to wait on prerequisite services).
- `post_recovery_replay` — once after replay (async).

### Operator API

The recovery/operator API lives on `ProcessHub.Service.Recovery`:

```elixir
Recovery.recovery_state(:my_hub)         # :recovering | :normal
Recovery.await_normal(:my_hub, 30_000)   # :ok | {:error, :timeout}

# Arm the local node (delete the marker) for recovery on next boot.
Recovery.prepare_recovery(:my_hub)       # :ok | {:error, term}

# Arm every hub member via :rpc.multicall/4.
Recovery.prepare_recovery_cluster(:my_hub)
# => {:ok, [node]} | {:partial, acked, unreachable} | {:error, term}
```

`prepare_recovery/1` only deletes the marker; the running coordinator is
not interrupted. Wrap `prepare_recovery_cluster/1` in your ops CLI for a
planned "drain & rebuild from disk" restart — for a rolling restart, leave
the markers in place and let peers dominate. On hubs with
`auto_recovery: false` these calls are no-ops returning `:ok`.

Recommended with a persistent backend: with the default `:ets` backend the
registry is empty on every restart, so recovery replays zero rows and
provides no restart-survival.

### Failure modes

- **Corrupt DETS in recovery mode** — file is rotated, recovery runs
  against an empty registry and reaches `:normal` with `cspec_count: 0`.
- **Marker write failure** — logged at ERROR; the coordinator continues as
  `:normal`, and the next boot recovers again (fail-safe: a node that
  cannot record "I am healthy" defaults to "I might not be").
- **Ephemeral storage** — the marker and DETS paths must share the same
  persistent volume; ephemeral pods cannot use these backends anyway.

To disable recovery entirely, set `auto_recovery: false`: the coordinator
reaches `:normal` at `init/1` with no marker IO, exactly as before.

## Hybrid backend (`:durable_ets`)

`{:durable_ets, opts}` keeps an in-memory ETS table as the source of truth
for reads and writes, mirroring every mutation synchronously to a DETS
file. On open the DETS file is replayed into ETS so reads are immediately
authoritative.

- **Reads** (`get`, `exists?`, `foldl`, `match`, `export_all`) hit ETS
  only — hot-path callers pay no DETS cost.
- **Writes** (`insert`, `remove`, `clear_all`) write ETS, then DETS, then
  `:dets.sync/1` before returning; once `:ok` is observed the row is
  durable. A failed DETS write rolls back the ETS write and returns
  `{:error, reason}`.
- **Crash window** — a write in memory but not yet synced is lost on
  restart, identical to `{:dets, _}`.

| Concern | `:ets` | `{:dets, _}` | `{:durable_ets, _}` |
| --- | --- | --- | --- |
| Read latency | ETS | DETS (slower) | ETS |
| Write latency | ETS | DETS + `fsync` | ETS + DETS + `fsync` |
| Restart-survival | no | yes | yes |
| RAM footprint | rows in RAM | metadata only | rows in RAM |
| Disk footprint | none | rows on disk | rows on disk |

Pick `{:durable_ets, _}` when reads dominate and restart-survival matters;
`{:dets, _}` when writes dominate and RAM is constrained; `:ets` when
neither restart-survival nor disk durability is required.
