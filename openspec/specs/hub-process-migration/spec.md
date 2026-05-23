# hub-process-migration Specification

## Purpose
TBD - created by archiving change cluster-leadership-and-migration. Update Purpose after archive.
## Requirements
### Requirement: A process SHALL be migratable from one hub to another with state handoff

ProcessHub SHALL provide a basic operation to migrate a process from a source hub to a
target hub: stop it on the source, start it on the target, and hand the previous process's
state to the new one. State handoff SHALL be explicit via a small contract the migrated
process implements (export the state on the source, import it on the target) — ProcessHub
SHALL NOT attempt transparent state capture. The target node SHALL be chosen by the target
hub's normal distribution strategy.

#### Scenario: Process moves to the target hub carrying its state
- **GIVEN** a process registered in source hub A holding some state
- **WHEN** it is migrated to target hub B
- **THEN** it SHALL no longer be running/registered in hub A
- **AND** it SHALL be running/registered in hub B initialized with the exported state

### Requirement: Migration SHALL be coordinated (serialized and de-duplicated) by the oracle

A migration request SHALL be delegated to the oracle (on the leader), which SHALL serialize
migrations per process so two nodes cannot migrate the same process concurrently, and SHALL
de-duplicate redundant requests for an in-flight or completed migration.

#### Scenario: Concurrent migrations of the same process do not double-start
- **GIVEN** two nodes request migration of the same process at the same time
- **WHEN** the oracle processes the requests
- **THEN** the process SHALL be migrated at most once (no two live copies in the target hub)

### Requirement: Migration SHALL preserve the process across mid-operation failure

The oracle SHALL own the migration sequence (freeze → snapshot → stop on source → start on
target → commit) so a failure of the target start does not lose the process: on failure the
oracle SHALL roll back (restart the process on the source with the snapshot).

The oracle is the migration's durable owner and fails over with leadership, so coordination
survives leader changes. Replicating the state of a migration that is *in flight at the exact
moment the oracle crashes* (so a successor oracle could resume that specific sequence) is the
documented elector availability-vs-CP trade-off (see `design.md` D3) and is out of scope for
this basic feature; per-process migration tokens make redundant requests idempotent.

#### Scenario: Target start fails → process restored on the source
- **GIVEN** a migration whose target-hub start fails after the source process was stopped
- **WHEN** the oracle handles the failure
- **THEN** the process SHALL be restarted on the source hub with the snapshot state
- **AND** the process SHALL NOT be lost (it exists in exactly one hub afterward)

#### Scenario: No lost updates during handoff
- **GIVEN** a process actively handling work on the source hub
- **WHEN** it is migrated
- **THEN** its state SHALL be frozen before the snapshot is taken so updates are not lost between snapshot and stop

