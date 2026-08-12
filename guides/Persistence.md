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

## Registry convergence and orphan recovery

> #### Experimental {: .warning}
>
> The `:auto_recovery` lifecycle is **experimental** and may change. The
> persistence backends above are not affected by this notice.

A node cannot answer "does the cluster already hold my children?" from its own
disk. So nothing asks it. Instead each node periodically computes a difference:

```
orphans = durable candidates − children observed running anywhere − stopped rows
```

and starts the remainder through the normal start path with
`check_existing: true`. The same code covers both directions: after a
whole-cluster outage the live registry is empty and everything returns; after a
single-node rejoin the peers already hold the children and the difference is
empty; a child stopped during the absence has a `:stopped` row and stays dead.

### Row bookkeeping

Every row carries hub-owned state under the reserved metadata key
`:__process_hub__`: `epoch`, `lifecycle` (`:running | :stopped`), `changed_by`,
`changed_at` (diagnostics only), and `stopped_at` while stopped.

Every write that *authors* a row increments `epoch`. Merges resolve by higher
epoch, ties by the lexicographically lower `changed_by`, and adopt the winner
verbatim — so every node converges on the same value in any order. The epoch is a
counter, never a wall clock: hardware without a battery-backed clock boots with a
bogus time exactly when it rejoins and merges. Caller metadata cannot set the key.

`node_pids` is not part of that resolution. It is a set of per-node observations,
each owned by the node it names — a payload from node `N` only touches the
`{N, pid}` entry, and a child missing from `N`'s payload removes nothing else.
**No absence observation deletes durable state.**

### Stopped is a row, not a deletion

`stop_children/3` marks the row `:stopped` with `node_pids: []` rather than
deleting it, so a node that was down during the stop adopts the row on its return
instead of resurrecting the child. Starting the same child_id again flips it back.
A `:temporary` or `:transient` child the supervisor declines to restart gets the
same treatment.

The row expires at `stopped_at + stopped_row_ttl_ms` — an absolute deadline every
node recomputes identically, so re-synchronisation cannot extend it — and is swept
by the janitor. That TTL is also the bound on how long a node may be absent and
still be prevented from resurrecting a child stopped meanwhile.

### Rounds and states

`:recovery_state` is `:recovering` until the first round completes, then `:normal`
(terminal). With `auto_recovery: false` it is `:normal` from `init/1`.

The first round runs `reconcile_grace_ms` after start, with or without peers, so
`:normal` is always reached. Later rounds follow completed synchronisation rounds,
rate-limited to one per `reconcile_interval_ms`.

Every node holding a candidate submits it — a candidate's only durable copy may
live on a non-owner node. Duplicates are prevented by `check_existing: true` and
by the ring routing concurrent submissions to the same owner, where the supervisor
rejects the second. A round also reduces a child observed on more than one node to
its ring owner's instance.

### Configuration

```elixir
%ProcessHub{
  hub_id: :my_hub,
  registry_backend: {:durable_ets, []},
  auto_recovery: [
    reconcile_grace_ms: 30_000,
    reconcile_interval_ms: 15_000,
    stopped_row_ttl_ms: 86_400_000
  ]
}
```

- `:reconcile_grace_ms` — delay before the first round. Default `30_000`, range
  `[1_000, 600_000]`. **Set it above your synchronization strategy's
  `sync_interval`**; ProcessHub warns at init when it is not.
- `:reconcile_interval_ms` — minimum spacing between rounds, and the per-handler
  budget for the blocking `pre_recovery_replay` hook. Default `15_000`, same range.
- `:stopped_row_ttl_ms` — how long a stopped row survives past `stopped_at`.
  Default `86_400_000` (24 h), range `[60_000, 31_536_000_000]`.

The marker-era keys `:marker_path`, `:replay_timeout_ms` and
`:recovery_timeout_ms` are deprecated: accepted with a WARN, ignored, and rejected
in a later release. So are `Recovery.prepare_recovery/1` and
`prepare_recovery_cluster/1`, now no-ops. See `migration-guide.md`.

An opted-in hub opens its backend with `recovery_replay: false`: durable rows
reach the cluster through the reconcile, never through the backend open, so a
returning node cannot republish its stale view as fact. A hub on `:ets` has no
durable candidates and starts nothing.

### Hooks

- `recovery_state_changed` — the `:recovering → :normal` transition (async).
- `pre_recovery_replay` — once, before the **first** round issues any start.
  **Synchronous**: use it to wait on prerequisite services.
- `post_recovery_replay` — once, after the first round completes (async).
- `reconcile_round` — every round, including quiet ones, with `candidates`,
  `orphans`, `started`, `skipped_pending`, `duplicates`, `elapsed_ms`.
- `reconcile_duplicate` — emitted by the node stopping its own duplicate instance.

### Introspection and failure modes

```elixir
Recovery.recovery_state(:my_hub)         # :recovering | :normal
Recovery.await_normal(:my_hub, 60_000)   # :ok | {:error, :timeout}
```

`await_normal/2` returns once the first round has completed. Size the timeout
above `reconcile_grace_ms`.

- **Unreadable durable medium** — the round performs no starts and no duplicate
  resolution; a transient failure is never read as "everything was removed".
- **A child mid-migration** — a registered row that is momentarily unbound must be
  an orphan in two consecutive rounds before it is started.

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
