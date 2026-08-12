# registry-convergence Specification

## Purpose
TBD - created by archiving change registry-convergence-and-orphan-recovery. Update Purpose after archive.
## Requirements
### Requirement: Registry rows carry a monotonic per-child epoch

Every registry row SHALL carry ProcessHub-owned bookkeeping under the reserved
metadata key `:__process_hub__`, holding at least:

```elixir
%{
  epoch: pos_integer(),
  lifecycle: :running | :stopped,
  changed_at: integer(),          # System.system_time(:millisecond), diagnostics only
  changed_by: node()
}
```

Every mutation of a child's row through `ProcessHub.Service.ProcessRegistry`
(`insert/4`, `update/3`, `bulk_delete`, lifecycle transitions) SHALL set
`epoch = previous_epoch + 1`, where `previous_epoch` is `0` for a child_id the local
registry has not seen. The epoch SHALL be a counter; no ordering decision anywhere in
the system may derive from `changed_at` or any other wall-clock value.

The reserved key SHALL be invisible to the caller-supplied metadata contract: metadata
passed to `insert/4` or returned by an `update_fn` SHALL NOT be able to set or clear
`:__process_hub__`, and a caller writing that key SHALL have it ignored with a WARN log.

#### Scenario: Epoch increments on every write

- **GIVEN** a child `cid_a` registered on a hub, with `epoch: 1`
- **WHEN** its metadata is updated twice through `ProcessRegistry.update/3`
- **THEN** the row's `:__process_hub__.epoch` is `3`
- **AND** each intermediate value was written durably before the next update

#### Scenario: First registration starts at epoch 1

- **GIVEN** a hub with no row for `cid_new`
- **WHEN** `cid_new` is started and registered
- **THEN** the row's `:__process_hub__.epoch` is `1` and `lifecycle` is `:running`

#### Scenario: Caller cannot forge the reserved key

- **GIVEN** a caller invoking `ProcessRegistry.insert/4` with
  `metadata: %{__process_hub__: %{epoch: 9_999}}`
- **WHEN** the row is written
- **THEN** the stored `:__process_hub__.epoch` is the hub-computed value, not `9_999`
- **AND** a WARN log identifies the attempted reserved-key write

### Requirement: Replica merges resolve by epoch, then node name

A merge of a peer's registry row SHALL resolve to the copy with the higher `epoch` —
its `child_spec`, its caller metadata, and its `:__process_hub__` map. On equal epochs
the copy from the lexicographically lower `changed_by` node name SHALL win. The outcome
SHALL be identical on every node that performs the merge, in any order, with any number
of repetitions.

This replaces the previous rule in `Synchronizer.append_data/2`, which kept the local
`child_spec` and metadata unconditionally.

Merging SHALL NOT change the local `node_pids` observations (see the observed-liveness
requirement) and SHALL NOT increment the epoch — a merge adopts a value, it does not
author one.

#### Scenario: Higher epoch wins regardless of which side is local

- **GIVEN** node A holds `cid_a` at `epoch: 4` and node B holds `cid_a` at `epoch: 7`
  with a different `child_spec`
- **WHEN** A and B exchange sync payloads in either order
- **THEN** both nodes converge on B's `child_spec` and `epoch: 7`
- **AND** neither node's epoch is incremented by the merge itself

#### Scenario: Equal epochs resolve by node name

- **GIVEN** nodes `a@host` and `b@host` each hold `cid_a` at `epoch: 5` with different
  metadata, authored independently during a partition
- **WHEN** the partition heals and both merge
- **THEN** both converge on the copy whose `changed_by` is `a@host`

#### Scenario: Stale returning node loses to the cluster

- **GIVEN** node A was down while the cluster advanced `cid_a` from `epoch: 3` to
  `epoch: 6`
- **WHEN** A returns holding `epoch: 3` and syncs
- **THEN** A adopts the `epoch: 6` row
- **AND** A's durable copy is overwritten with the adopted row

### Requirement: `node_pids` is observed liveness, never merged truth

A registry row's `node_pids` list SHALL be treated as a set of per-node observations,
each owned exclusively by the node it names:

- A sync payload from node `N` SHALL only add, update, or remove the `{N, pid}` entry.
- The absence of a child from node `N`'s payload SHALL NOT remove that child's row, and
  SHALL NOT remove entries owned by any node other than `N`.
- A row SHALL NOT be deleted because its `node_pids` list became empty. Rows leave the
  registry only through an explicit lifecycle transition or through expiry.

`Synchronizer.detach_data/2`'s absence-driven row deletion SHALL be removed. Placement
SHALL continue to be recomputed by the migration tick after the cluster forms, as the
cspecs-only replay contract already requires.

#### Scenario: Empty payload from a booting peer deletes nothing

- **GIVEN** a 2-node cluster A/B where A holds 3 children and B has just started with
  an empty registry
- **WHEN** B's first sync payload — containing no children — reaches A
- **THEN** A's 3 rows are unchanged in memory and on disk
- **AND** no row's `node_pids` entry for A is touched

#### Scenario: A node's payload only affects its own observations

- **GIVEN** `cid_a` is observed as `[{A, pid_a}, {B, pid_b}]` on every node
- **WHEN** A reports `cid_a` as no longer running locally
- **THEN** the `{A, pid_a}` entry is removed on every node
- **AND** `{B, pid_b}` is retained
- **AND** the row itself survives with `lifecycle: :running`

#### Scenario: Row survives an empty pid list

- **GIVEN** `cid_a` whose last observed pid is removed after its node reports it gone
- **WHEN** the registry is inspected
- **THEN** the row is present with `node_pids: []` and `lifecycle: :running`
- **AND** it is a candidate for the next orphan reconcile round

### Requirement: Stopping a child preserves its row

A deliberate stop SHALL transition the child's row to `lifecycle: :stopped` rather than
deleting it. This applies to `ProcessHub.stop_children/3` and to every internal path
that deliberately terminates a child:

- `node_pids` is cleared,
- `epoch` is incremented,
- `:__process_hub__.stopped_at` is set to the current system time in milliseconds,
- the row is given the expiry described in the stopped-row-expiry requirement.

Starting the same child_id again SHALL transition the row back to `lifecycle: :running`
with an incremented epoch, clear `stopped_at`, and remove the expiry.

A `:stopped` row SHALL be excluded from the orphan candidate set on every node,
including nodes whose durable copy still shows the child as `:running` at a lower
epoch.

#### Scenario: Stop leaves a durable stopped row

- **GIVEN** `cid_a` running on a hub with a durable registry backend
- **WHEN** `ProcessHub.stop_children(hub_id, ["cid_a"])` completes
- **THEN** the row is present with `lifecycle: :stopped`, `node_pids: []`, and an
  incremented epoch
- **AND** the row is present in the on-disk registry file after close and re-open

#### Scenario: A stop during a node's absence is honoured on its return

- **GIVEN** node A is down and its durable registry holds `cid_a` as `:running` at
  `epoch: 4`
- **WHEN** `cid_a` is stopped on the surviving cluster (row moves to `:stopped` at
  `epoch: 5`) and A then returns and syncs
- **THEN** A adopts the `:stopped` row at `epoch: 5`
- **AND** `cid_a` is absent from A's orphan candidate set
- **AND** `cid_a` is not started anywhere

#### Scenario: Restart clears the stopped state

- **GIVEN** `cid_a` with a `:stopped` row at `epoch: 5`
- **WHEN** `ProcessHub.start_children(hub_id, [cspec_a])` is called for the same
  child_id
- **THEN** the row is `lifecycle: :running` at `epoch: 6` with `stopped_at` cleared and
  no expiry
- **AND** the row's expiry no longer appears in the durable backend

### Requirement: Stopped rows expire on an absolute deadline

A `:stopped` row SHALL carry an expiry of `stopped_at + stopped_row_ttl_ms`, computed
from the row's own `stopped_at` value rather than from the time of any individual
write. Default `stopped_row_ttl_ms` is `86_400_000` (24 hours); the accepted range is
`[60_000, 31_536_000_000]` (1 minute to 1 year).

Because the deadline is derived from a merged field, every node that adopts the row
SHALL compute the same absolute expiry, and re-writing the row during synchronisation
SHALL NOT extend its lifetime. Expired rows SHALL be removed by the existing janitor
sweep (`ProcessHub.Worker.Janitor.purge_pending_registry/1` →
`ProcessRegistry.delete_if_expired/2`); this change adds no second sweeper.

The TTL is the bound on how long a node may be absent and still be prevented from
resurrecting a child stopped during its absence. Operators lengthening planned outages
beyond the TTL SHALL raise it.

#### Scenario: Expiry survives re-synchronisation unchanged

- **GIVEN** a `:stopped` row with `stopped_at: T` and `stopped_row_ttl_ms: 86_400_000`
- **WHEN** the row is exchanged and re-written by 20 subsequent sync rounds
- **THEN** its expiry is `T + 86_400_000` after every round
- **AND** it is swept by the janitor at that deadline, not later

#### Scenario: Expired stopped row is removed

- **GIVEN** a `:stopped` row whose expiry has passed, on a `{:durable_ets, _}` backend
- **WHEN** the janitor sweep runs
- **THEN** the row is absent from both the live registry and the on-disk file

#### Scenario: Out-of-range TTL rejected

- **GIVEN** `auto_recovery: [stopped_row_ttl_ms: 1_000]` (below the `60_000` minimum)
- **WHEN** the coordinator initialises
- **THEN** init fails with
  `{:error, {:invalid_auto_recovery, :stopped_row_ttl_ms_out_of_range}}`

### Requirement: Orphan reconcile round

When `:auto_recovery` is enabled, a node SHALL periodically reconcile its durable
registry against the cluster's live registry. A round SHALL:

1. Read the durable candidate set through the backend's durable-read callback, without
   populating or mutating the live registry.
2. Compute
   `orphans = candidates − children observed running anywhere − rows with lifecycle :stopped`.
3. Exclude any child whose row has been an orphan for fewer than two consecutive
   rounds, so a child that is merely mid-migration is not restarted.
4. Exclude any child whose ring owner is a node currently draining.
5. Dispatch the `pre_recovery_replay` hook (synchronously, blocking) before the first
   round of a coordinator's lifetime issues any start.
6. Submit the remaining orphans through `Distributor.compose_start_operation/3` with
   `check_existing: true` and `auto_recovery_replay: true`.
7. Dispatch the `post_recovery_replay` hook (async) after the first round completes.

Every node that holds a candidate on disk SHALL submit it; submission SHALL NOT be
restricted to the ring owner, because a candidate's only durable copy may live on a
non-owner node. Duplicate submissions are resolved by `check_existing: true` and by the
ring routing both submissions to the same owner, where the supervisor rejects the
second with `already_started`.

The first round SHALL run no earlier than `reconcile_grace_ms` (default `30_000`) after
coordinator start, and thereafter at most once per `reconcile_interval_ms` (default
`15_000`), triggered by the completion of a synchronisation round. The first round
SHALL run when the grace elapses whether or not any peer has joined.

A hub whose registry backend is `:ets` has no durable candidates and SHALL perform no
starts.

#### Scenario: Whole-cluster restart restores every child

- **GIVEN** a 2-node cluster where A's durable registry holds `cid_a`, `cid_b` and B's
  holds `cid_c`, all `lifecycle: :running`, and both nodes are restarted with no
  children running
- **WHEN** the first reconcile round runs on each node after the grace window
- **THEN** the orphan set on A is `{cid_a, cid_b}` and on B is `{cid_c}`
- **AND** all three children are started exactly once, each on its ring owner
- **AND** no operator action was required

#### Scenario: Rejoining a live cluster starts nothing

- **GIVEN** node A crashed, B migrated `cid_a` and `cid_b` to itself, and A returns
  with both still `:running` on its disk
- **WHEN** A's first reconcile round runs
- **THEN** both children are observed running on B, so the orphan set is empty
- **AND** A starts no child

#### Scenario: A child mid-migration is not restarted

- **GIVEN** `cid_a` is unbound at the moment of a round because a migration is in
  flight
- **WHEN** that round computes the orphan set
- **THEN** `cid_a` is recorded as a first-round orphan but not started
- **AND** it is started only if it is still unaccounted for in the next round

#### Scenario: Stopped children are never orphans

- **GIVEN** a durable registry with 5 rows, of which 2 are `lifecycle: :stopped`
- **WHEN** a reconcile round runs on an otherwise empty cluster
- **THEN** exactly 3 children are started
- **AND** the 2 stopped rows are untouched, retaining their expiry

#### Scenario: Reconcile is a no-op on the `:ets` backend

- **GIVEN** a hub with `registry_backend: :ets` and `auto_recovery: true`
- **WHEN** reconcile rounds run
- **THEN** the durable candidate set is empty and no child is started

#### Scenario: Grace window elapses with no peers

- **GIVEN** a single node booting alone with `reconcile_grace_ms: 30_000` and 3 durable
  candidates
- **WHEN** 30 s elapse with no peer joining
- **THEN** the first round runs and starts all 3 children
- **AND** `recovery_state/1` returns `:normal` afterwards

### Requirement: Duplicate-binding resolution

A reconcile round SHALL detect children observed running on more than one node and
resolve each by stopping every instance except the one on the child's ring owner. If
none of the observed instances is on the ring owner, the instance on the
lexicographically lowest node name SHALL be kept.

Each resolution SHALL emit `[:process_hub, :reconcile, :duplicate]` telemetry with
measurements `%{instance_count: N}` and metadata `%{hub_id, child_id, kept_node,
stopped_nodes}`, and SHALL be logged at WARN. Resolution SHALL NOT increment the row's
epoch beyond the single lifecycle write it performs.

#### Scenario: Double-bound child is reduced to one instance

- **GIVEN** `cid_a` observed running on both A and B, with the ring assigning `cid_a`
  to B
- **WHEN** a reconcile round runs
- **THEN** the instance on A is stopped and the instance on B is retained
- **AND** a `[:process_hub, :reconcile, :duplicate]` event is emitted with
  `instance_count: 2`, `kept_node: B`, `stopped_nodes: [A]`
- **AND** the row remains `lifecycle: :running`

#### Scenario: Neither instance is on the ring owner

- **GIVEN** `cid_a` observed on `b@host` and `c@host` while the ring assigns it to
  `a@host`, which is unreachable
- **WHEN** a reconcile round runs
- **THEN** the instance on `b@host` is kept and the one on `c@host` is stopped

### Requirement: Reconcile telemetry

ProcessHub SHALL emit `[:telemetry]`-compatible events for the reconcile lifecycle:

- `[:process_hub, :reconcile, :round]` — emitted at the end of every round.
  Measurements: `%{candidates, orphans, started, skipped_pending, duplicates,
  elapsed_ms}`. Metadata: `%{hub_id, first_round: boolean()}`.
- `[:process_hub, :reconcile, :duplicate]` — as specified in the duplicate-binding
  requirement.

Rounds that find nothing SHALL still emit `:round`, so a silent reconcile is
distinguishable from a stalled one.

#### Scenario: Quiet round is still observable

- **GIVEN** a healthy cluster where every durable candidate is observed running
- **WHEN** a reconcile round completes
- **THEN** one `[:process_hub, :reconcile, :round]` event is emitted with
  `orphans: 0, started: 0`

#### Scenario: Restoring round reports what it started

- **GIVEN** 3 durable candidates and an empty live registry
- **WHEN** the first round completes
- **THEN** one `:round` event is emitted with `candidates: 3, orphans: 3, started: 3`
  and `first_round: true`

