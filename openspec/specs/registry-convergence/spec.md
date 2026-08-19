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

### Requirement: Orphan reconcile round

When `:auto_recovery` is enabled, a node SHALL periodically reconcile the
hub's declared list against the cluster's live registry. A round SHALL:

1. Take the declared list as the candidate set. Durable registry rows are no
   longer a candidate source.
2. Compute `orphans = declared children − children observed running
   anywhere`.
3. Stop any child observed running whose row is marked durable but whose id
   is absent from the declared list (a stop that crashed between list removal
   and terminate); children never declared are untouched.
4. Remove registry rows marked durable that are undeclared and observed
   running nowhere for two consecutive rounds (hygiene against stale
   rejoining peers re-introducing deleted rows).
5. Exclude any child that has been an orphan for fewer than two consecutive
   rounds, so a child that is merely mid-migration is not restarted.
6. Exclude any child whose ring owner is a node currently draining.
7. Dispatch the `pre_recovery_replay` hook (synchronously, blocking) before
   the first round of a coordinator's lifetime issues any start.
8. Submit the remaining orphans through
   `Distributor.compose_start_operation/3` with `check_existing: true` and
   `auto_recovery_replay: true`.
9. Dispatch the `post_recovery_replay` hook (async) after the first round
   completes.

Every node SHALL submit from its adopted copy of the list; submission SHALL
NOT be restricted to the ring owner. Duplicate submissions are resolved by
`check_existing: true` and by the ring routing both submissions to the same
owner, where the supervisor rejects the second with `already_started`.

The first round SHALL run no earlier than `reconcile_grace_ms` (default
`30_000`) after coordinator start, and thereafter at most once per
`reconcile_interval_ms` (default `15_000`), triggered by the completion of a
synchronisation round. The first round SHALL run when the grace elapses
whether or not any peer has joined. When the declared list is parked
(missing/corrupt with durable evidence and no remote copy), the round SHALL
start and stop nothing for that hub.

A hub whose declared list is empty has no candidates and SHALL perform no
starts.

#### Scenario: Whole-cluster restart restores every declared child

- **GIVEN** a 2-node cluster whose declared list (version-adopted on both
  nodes) holds `cid_a`, `cid_b`, `cid_c`, and both nodes are restarted with
  no children running
- **WHEN** the first reconcile round runs on each node after the grace
  window
- **THEN** all three children are started exactly once, each on its ring
  owner
- **AND** no operator action was required

#### Scenario: Rejoining a live cluster starts nothing

- **GIVEN** node A crashed, B migrated `cid_a` and `cid_b` to itself, and A
  returns with a declared list still containing both
- **WHEN** A's first reconcile round runs
- **THEN** both children are observed running on B, so the orphan set is
  empty
- **AND** A starts no child

#### Scenario: A child mid-migration is not restarted

- **GIVEN** `cid_a` is unbound at the moment of a round because a migration
  is in flight
- **WHEN** that round computes the orphan set
- **THEN** `cid_a` is recorded as a first-round orphan but not started
- **AND** it is started only if it is still unaccounted for in the next
  round

#### Scenario: Stopped declared children are never orphans, without tombstones

- **GIVEN** a declared list of 3 children after 2 further children were
  deliberately stopped (list entries removed)
- **WHEN** a reconcile round runs on an otherwise empty cluster
- **THEN** exactly 3 children are started and the 2 stopped ids are not
  candidates, regardless of how long ago the stops happened

#### Scenario: Undeclared running child is stopped

- **GIVEN** a child observed running whose id was previously declared but is
  absent from the current declared list
- **WHEN** a reconcile round runs
- **THEN** the round stops that child

#### Scenario: Stale peer's ghost row is cleaned up

- **GIVEN** a rejoining node whose sync payload re-introduced a row for a
  child that was stopped (list entry and row both removed) while it was down
- **WHEN** a reconcile round observes the row undeclared and running nowhere
- **THEN** the row is removed and the child is not started

#### Scenario: Grace window elapses with no peers

- **GIVEN** a single node booting alone with `reconcile_grace_ms: 30_000`
  and 3 declared children
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

