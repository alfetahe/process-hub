# cluster-oracle Specification

## Purpose
TBD - created by archiving change cluster-leadership-and-migration. Update Purpose after archive.
## Requirements
### Requirement: The oracle SHALL be a single authoritative service running on the leader

ProcessHub SHALL provide an oracle service (`ProcessHub.Service.Oracle`) that runs as
exactly one instance in the cluster, on the elected leader node, and is the authoritative
source of truth for cluster coordination — it is the single writer/source-of-record, so
other parties ask it or submit requests to it rather than writing that truth themselves.
The oracle SHALL be distinct from leadership: the leader is the node; the oracle is the
service that runs there. The oracle SHALL require leadership to be started.

#### Scenario: Exactly one oracle, on the leader
- **GIVEN** a cluster with leadership started
- **WHEN** the oracle is running
- **THEN** there SHALL be exactly one oracle instance, located on the leader node

#### Scenario: The oracle's view is self-consistent
- **WHEN** any party reads coordination state (directory, in-flight work) from the oracle
- **THEN** the answer SHALL be the oracle's own record, which is internally consistent (no contradicting writers)

### Requirement: The oracle SHALL fail over with leadership and rebuild its state

When leadership moves to a new node, a fresh oracle SHALL start on the new leader and
rebuild its directory from hub re-announcement (driven by the leadership-change
subscription), so the oracle's state is reconstructable without replication.

#### Scenario: Oracle rebuilds after a leadership change
- **GIVEN** an oracle holding a hub directory on the current leader
- **WHEN** leadership moves to another node
- **THEN** a new oracle SHALL start on the new leader
- **AND** hubs SHALL re-announce so the new oracle's directory converges to the current set of hubs

### Requirement: The oracle SHALL expose cluster information and stats

The oracle SHALL answer cluster-coordination queries — at minimum the current leader, the
known hubs, and basic per-hub/cluster stats — giving consumers a single place to interact
with and observe the cluster.

#### Scenario: Query cluster info from the oracle
- **WHEN** a consumer asks the oracle for cluster info
- **THEN** it SHALL return the current leader, the registered hubs, and basic stats

### Requirement: The oracle SHALL host a hub directory

Hubs SHALL be able to announce themselves to the oracle with identity, node, and metadata;
the oracle SHALL maintain the resulting directory and answer discovery queries
("which hubs exist / where"). Participation SHALL be opt-in so isolated hubs are unaffected.

#### Scenario: Announce and discover
- **GIVEN** hubs that have announced to the oracle
- **WHEN** a consumer lists hubs via the oracle
- **THEN** it SHALL return the announced hubs with their node and metadata

#### Scenario: Non-participating hubs stay isolated
- **GIVEN** a hub that does not opt into the directory
- **WHEN** the directory is listed
- **THEN** that hub SHALL NOT appear and its behavior SHALL be unchanged

### Requirement: The oracle SHALL be the single serializer for cluster-singleton coordination

The oracle SHALL serialize and de-duplicate cluster-singleton coordination work — work that
must happen at most once cluster-wide (for example hub-to-hub process migration) — so two
nodes cannot drive the same coordination operation concurrently; such work SHALL be
submitted to the oracle rather than performed independently per node.

#### Scenario: Concurrent identical requests are de-duplicated
- **GIVEN** two nodes submit the same coordination request to the oracle near-simultaneously
- **WHEN** the oracle processes them
- **THEN** the operation SHALL be admitted at most once (the second observes the in-progress/completed state and does not re-run it)

