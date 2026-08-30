# declared-children Specification

## Purpose
A versioned, durable, leader-written list of the children that SHALL exist on a
hub: `durable: true` starts add, deliberate stops remove, and the orphan
reconcile converges the cluster toward it. List absence is the stop record — it
never expires — closing the resurrection and tombstone-accumulation holes of
row-based stop memory. Experimental, gated on `:auto_recovery`.
## Requirements
### Requirement: The declared list is mutated only by start and stop, through the leader

A hub with `:auto_recovery` enabled SHALL maintain a durable *declared list*:
the specs of every child started with `durable: true` that has not been
deliberately stopped. `start_child` with `durable: true` SHALL add the
child's spec; a deliberate stop SHALL remove it. Both mutations SHALL be
serialized through the hub's leader node, which increments a monotonic list
version by one per mutation and persists the new list before acknowledging.
No other code path SHALL mutate the list — process death, node churn,
synchronisation, and reconcile rounds never write it.

The list mutation SHALL commit before the process action: the add before the
child is started, the removal before the child is terminated. When no leader
is reachable, the mutation SHALL fail with `{:error, :no_leader}` without
starting or stopping anything; commands for children without `durable: true`
SHALL be unaffected.

Declared-list membership SHALL NOT expire: absence is the durable stop
record. List size is therefore bounded by the number of currently declared
children, independent of start/stop churn history.

#### Scenario: Start adds, stop removes

- **WHEN** a child is started with `durable: true` and later deliberately
  stopped
- **THEN** the declared list contains its spec between the two commands and
  does not contain it afterwards, with no tombstone left behind
- **AND** the list version incremented once per mutation

#### Scenario: Crash between removal and terminate converges to stopped

- **GIVEN** a stop that committed the list removal and then crashed before
  terminating the child
- **WHEN** the next reconcile round observes the child running but
  undeclared
- **THEN** the round stops the child

#### Scenario: No leader refuses the durable command only

- **GIVEN** a hub whose leader is unreachable
- **WHEN** `start_child` is called with `durable: true` and again without it
- **THEN** the durable call returns `{:error, :no_leader}` and no process is
  started for it
- **AND** the non-durable call proceeds normally

#### Scenario: A node absent beyond any TTL cannot resurrect

- **GIVEN** a declared child stopped while node B was down, and B returns
  after an arbitrarily long absence
- **WHEN** B adopts the cluster's declared list and its reconcile round runs
- **THEN** the child is not started, because it is absent from the list

### Requirement: `durable: true` requires a `:permanent` restart type

`start_child` with `durable: true` SHALL be refused with
`{:error, :durable_requires_permanent}` unless the child spec's restart type
is `:permanent` (explicitly or by default). A `:transient` or `:temporary`
child's normal self-exit is knowable only on its own node, so the reconcile
could not distinguish "finished" from "lost" and would resurrect completed
work.

#### Scenario: Transient child refused

- **WHEN** `start_child` is called with `durable: true` and a child spec
  whose `restart` is `:transient`
- **THEN** the call returns `{:error, :durable_requires_permanent}` and
  neither the list nor the cluster is mutated

### Requirement: The declared list is adopted by version from local, peer, and remote copies

The declared list SHALL carry a monotonic version. Every node SHALL persist
its adopted copy durably beside the registry. Synchronisation SHALL exchange
the version while the feature gate is on; a node holding a lower version
SHALL adopt the higher-versioned list wholesale. On boot the hub SHALL adopt
the highest version among its local copy, its peers, and the remote manifest
(when configured). A version tie with differing content SHALL resolve to the
list last mutated by the lexicographically lowest node name and SHALL emit
`[:process_hub, :declared_set, :tiebreak]` telemetry at WARN. No ordering
decision SHALL derive from wall-clock time.

#### Scenario: Rejoining node adopts the newer list

- **GIVEN** node B went down holding list version 37 containing child 1, and
  the cluster stopped child 1 (now version 42)
- **WHEN** B rejoins and synchronises
- **THEN** B replaces its local list with version 42 and does not start
  child 1

#### Scenario: Version tie resolves deterministically

- **GIVEN** two partition sides that each mutated the list to version 43
  with different content under a non-locking partition strategy
- **WHEN** the partition heals
- **THEN** both sides converge on the list mutated by the lexicographically
  lowest node and the tiebreak telemetry is emitted on both

### Requirement: Reads expose the list and its version

`ProcessHub.Service.DeclaredChildren.declared_children/1` SHALL return the
declared child specs and
the current list version without mutating any state, answering from local
storage.

#### Scenario: Reader returns members and version

- **WHEN** `declared_children/1` is called on a hub with N declared children
- **THEN** it returns the N child specs and the current list version

### Requirement: First boot seeds the list from existing durable rows

A hub SHALL, when booting with `:auto_recovery` enabled and no stored
declared list, build list version 1 from its durable registry rows minus
rows marked stopped by the superseded lifecycle model, exactly once, and log
the seed.
The stored list SHALL carry a format marker; a boot encountering a newer
marker than it understands SHALL refuse to open the list rather than
reinterpret it.

#### Scenario: Existing deployment seeds once

- **GIVEN** a hub with durable registry rows for 3 running children and 1
  row marked stopped, and no stored declared list
- **WHEN** the hub boots with `:auto_recovery` enabled
- **THEN** the declared list is created at version 1 containing exactly the
  3 running children, and subsequent boots do not re-seed

### Requirement: A missing or corrupt local list is never treated as empty truth

A hub SHALL NOT reconcile against an empty declared list when the local copy
is unreadable or absent while durable evidence of declared children exists
(a remote manifest copy, or durable registry rows). It SHALL restore the
list from the remote manifest when one is configured; otherwise it SHALL
park the hub's reconcile, start nothing, and emit alarm-grade telemetry
until an operator intervenes. Only an explicit operator call SHALL clear a
declared list.

#### Scenario: Corrupt list with no remote parks the reconcile

- **GIVEN** a corrupt declared-list file, no configured remote manifest, and
  durable registry rows on disk
- **WHEN** the hub boots
- **THEN** no reconcile round starts or stops children for that hub and
  alarm-grade telemetry is emitted, instead of the list silently opening
  empty

### Requirement: The feature costs nothing while the gate is off

A hub with `:auto_recovery` disabled (the default) SHALL start no
list-related or election-related process, create no list file, and add no
field to synchronisation payloads. `start_child` with `durable: true` on such
a hub SHALL return an error naming the disabled gate rather than silently
ignoring the option. The removal of the superseded stopped-row lifecycle
(deliberate stops delete the row on every hub) is the one behaviour shared
with gated-off hubs; it replaces experimental machinery and is documented in
the migration guide.

#### Scenario: Gate off changes nothing

- **GIVEN** a hub with `:auto_recovery` disabled
- **WHEN** children are started, stopped, and synchronised across nodes
- **THEN** sync payloads contain no list version field, no list file exists,
  and no election is started

#### Scenario: Durable start on a gated-off hub errors

- **WHEN** `start_child` is called with `durable: true` on a hub with
  `:auto_recovery` disabled
- **THEN** an error naming the disabled gate is returned and no process is
  started

