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

## Declared children and orphan recovery

> #### Experimental {: .warning}
>
> The `:auto_recovery` lifecycle is **experimental** and may change. The
> persistence backends above are not affected by this notice.

With `:auto_recovery` enabled, a hub maintains a *declared list*: a versioned,
durable list of the children that SHALL exist. `start_child/3` with
`durable: true` adds the child's spec to it; a deliberate stop removes it; no
other code path writes it. Each node then periodically reconciles the cluster
toward the list:

```
orphans = declared children − children observed running anywhere
```

The remainder is started through the normal start path with
`check_existing: true`, and a running child whose declared entry was removed (a
stop that crashed halfway) is stopped. The same difference covers both
directions: after a whole-cluster outage the live registry is empty and every
declared child returns; after a single-node rejoin the peers already hold the
children and the difference is empty; a child stopped during the absence is
absent from the list and stays dead — **list absence is the stop record, and it
never expires**, so a node may be away arbitrarily long without resurrecting a
stopped child on return.

### The declared list

Mutations are serialized through the hub's leader node (elected via `:elector`,
validated against the hub's own cluster, with the lexicographically lowest hub
member as deterministic fallback). The leader increments one monotonic version
per mutation and persists before acknowledging, so "which copy is newer" is a
single integer comparison and adoption replaces the whole list. The list
mutation always commits before the process action — add before start, remove
before terminate — so either half of a crashed command heals in the next round.

Every node persists its adopted copy in its own DETS-backed store beside the
registry file (whatever the `:registry_backend`), and on boot adopts the
highest version among its local copy, its peers, and the remote manifest. With
no leader reachable, `durable: true` starts and stops of declared children
return `{:error, :no_leader}`; everything else stays leader-free.

`durable: true` requires a `:permanent` restart type (the default): a
`:transient` or `:temporary` child may finish on its own node, and no other
node could distinguish "finished" from "lost".

```elixir
ProcessHub.start_child(:my_hub, child_spec, durable: true)
ProcessHub.Service.DeclaredChildren.declared_children(:my_hub)
#=> %{version: 3, children: [%{id: :my_child, ...}]}
```

### Remote manifest

An optional off-cluster copy protects the list against the loss of every
cluster disk. Configure `remote_manifest: {module, opts}` inside
`:auto_recovery` with a module implementing `ProcessHub.Storage.RemoteManifest`
— built-in adapters are `ProcessHub.Storage.RemoteManifest.LocalPath`
(dependency-free; point it at storage that lives *outside* the cluster) and
`ProcessHub.Storage.RemoteManifest.S3` (behind the optional `:ex_aws_s3`
dependency, using conditional writes).

The leader ships every mutation asynchronously — retried with backoff,
coalescing superseded versions — and boot fetches the remote copy before the
first reconcile round: the higher version wins, whichever side holds it. A
failing or slow adapter never affects a command; failures emit the
`manifest_ship_failed` hook.

### A missing list is never empty truth

A missing or corrupt local list while durable evidence exists (a seeded marker
beside the list file, or durable registry rows) is not read as "nothing
declared": the hub restores from the remote manifest, or parks its reconcile —
starting and stopping nothing, emitting the alarm-grade `declared_parked` hook
— until an operator intervenes. The explicit operator call is
`ProcessHub.Service.DeclaredChildren.clear/1`.

On the first boot with the feature enabled and no stored list, the hub seeds
version 1 from its durable registry rows, once — so an existing deployment's
children carry over. The stored list has a format marker; a newer marker than
the running release understands refuses to open.

### Row bookkeeping

Every row carries hub-owned state under the reserved metadata key
`:__process_hub__`: `epoch`, `changed_by`, `changed_at` (diagnostics only), and
`durable: true` for declared children.

Every write that *authors* a row increments `epoch`. Merges resolve by higher
epoch, ties by the lexicographically lower `changed_by`, and adopt the winner
verbatim — so every node converges on the same value in any order. The epoch is a
counter, never a wall clock: hardware without a battery-backed clock boots with a
bogus time exactly when it rejoins and merges. Caller metadata cannot set the key.

`node_pids` is not part of that resolution. It is a set of per-node observations,
each owned by the node it names — a payload from node `N` only touches the
`{N, pid}` entry, and a child missing from `N`'s payload removes nothing else.
**No absence observation deletes durable state.**

A deliberate stop deletes the registry row (stop memory lives in the list); a
`:temporary` or `:transient` child the supervisor declines to restart gets the
same treatment. Placement churn leaves a short-lived stub swept by the janitor.

### Rounds and states

`:recovery_state` is `:recovering` until the first round completes, then `:normal`
(terminal). With `auto_recovery: false` it is `:normal` from `init/1`.

The first round runs `reconcile_grace_ms` after start, with or without peers, so
`:normal` is always reached. Later rounds follow completed synchronisation rounds,
rate-limited to one per `reconcile_interval_ms`.

Every node submits from its adopted copy of the list. Duplicates are prevented by
`check_existing: true` and by the ring routing concurrent submissions to the same
owner, where the supervisor rejects the second. A round also reduces a child
observed on more than one node to its ring owner's instance, and removes rows
marked durable that are undeclared and observed running nowhere (a stale
rejoining peer's leftovers).

### Configuration

```elixir
%ProcessHub{
  hub_id: :my_hub,
  auto_recovery: [
    reconcile_grace_ms: 30_000,
    reconcile_interval_ms: 15_000,
    remote_manifest: {ProcessHub.Storage.RemoteManifest.LocalPath, path: "/mnt/off-cluster"}
  ]
}
```

- `:reconcile_grace_ms` — delay before the first round. Default `30_000`, range
  `[50, 600_000]`. **Set it above your synchronization strategy's
  `sync_interval`**; ProcessHub warns at init when it is not.
- `:reconcile_interval_ms` — minimum spacing between rounds, and the per-handler
  budget for the blocking `pre_recovery_replay` hook. Default `15_000`, range
  `[1_000, 600_000]`.
- `:remote_manifest` — `{module, opts}` implementing
  `ProcessHub.Storage.RemoteManifest`. Default `nil` (disabled).

The superseded keys `:marker_path`, `:replay_timeout_ms`, `:recovery_timeout_ms`
and `:stopped_row_ttl_ms` are deprecated: accepted with a WARN, ignored, and
rejected in a later release. So are `Recovery.prepare_recovery/1` and
`prepare_recovery_cluster/1`, now no-ops. See `migration-guide.md`.

An opted-in hub opens its backend with `recovery_replay: false`: restoration
flows through the reconcile, never through the backend open, so a returning
node cannot republish its stale view as fact.

### Hooks

- `recovery_state_changed` — the `:recovering → :normal` transition (async).
- `pre_recovery_replay` — once, before the **first** round issues any start.
  **Synchronous**: use it to wait on prerequisite services.
- `post_recovery_replay` — once, after the first round completes (async).
- `reconcile_round` — every round, including quiet ones, with `candidates`,
  `orphans`, `started`, `skipped_pending`, `duplicates`, `stopped_undeclared`,
  `removed_stale`, `elapsed_ms`.
- `reconcile_duplicate` — emitted by the node stopping its own duplicate instance.
- `declared_tiebreak` — a version tie with differing content was resolved.
- `declared_parked` — alarm-grade: the list is lost and the reconcile is parked.
- `manifest_ship_failed` — a remote ship attempt failed; the shipper retries.

### Introspection and failure modes

```elixir
Recovery.recovery_state(:my_hub)         # :recovering | :normal
Recovery.await_normal(:my_hub, 60_000)   # :ok | {:error, :timeout}
DeclaredChildren.declared_children(:my_hub)  # %{version: v, children: [...]}
```

`await_normal/2` returns once the first round has completed. Size the timeout
above `reconcile_grace_ms`.

- **Parked list** — the round performs no starts and no stops; a lost list is
  never read as "nothing declared".
- **A child mid-migration** — a declared child with a registered but unbound row
  must be an orphan in two consecutive rounds before it is started.
- **Divergence partitions** — both sides mutating the list under a non-locking
  partition strategy resolve on heal by version, ties deterministically to the
  lowest mutating node (`declared_tiebreak` fires). Quorum strategies refuse the
  situation outright.

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
