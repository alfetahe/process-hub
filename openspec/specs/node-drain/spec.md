# node-drain Specification

## Purpose
TBD - created by archiving change migration-consent-and-drain. Update Purpose after archive.
## Requirements
### Requirement: Operator can drain a node before shutdown
The system SHALL provide `ProcessHub.drain(hub_id, opts)` — a blocking call that empties the local node of hub children before node shutdown. Draining SHALL remove the local node from the distribution (propagated cluster-wide) so that no new or existing children are assigned to it, and SHALL then migrate all local children away: consent-participating children through the consent protocol, all others immediately. The call SHALL return a summary of migrated and forced children.

#### Scenario: Successful drain
- **WHEN** `ProcessHub.drain(hub_id, timeout: t)` is called on a node in a healthy multi-node cluster
- **THEN** all local hub children are migrated to other nodes and the call returns `{:ok, %{migrated: n, forced: m}}`

#### Scenario: No new children during drain
- **WHEN** a child start is requested while the local node is draining
- **THEN** the distribution assigns the child to another node

#### Scenario: Consent respected during drain
- **WHEN** a consent-participating child replies `:defer` during a drain
- **THEN** it is deferred and retried incrementally, migrating as soon as it becomes ready, while non-deferring children migrate without waiting for it

### Requirement: Drain enforces a hard deadline
The drain call SHALL accept a `timeout` option (default 60000 ms) as a hard deadline. When the deadline is reached, all children still deferred SHALL be force-migrated using the existing best-effort state-query path, and the forced child ids SHALL be logged at warning level.

#### Scenario: Deadline forces remaining children
- **WHEN** the drain deadline is reached and deferred children remain
- **THEN** they are migrated without further consent, with state handover attempted, and the call returns with those children counted as forced

### Requirement: Drain fails safely when migration is impossible
The drain call SHALL validate preconditions before touching any children. If no other cluster node is available, or the hub is partitioned/locked, the call SHALL return an error and leave all children running locally.

#### Scenario: Single-node cluster
- **WHEN** `ProcessHub.drain/2` is called and no other node is in the cluster
- **THEN** `{:error, :no_target_nodes}` is returned and no child is stopped or migrated

#### Scenario: Partitioned hub
- **WHEN** `ProcessHub.drain/2` is called while the hub is in a partitioned/locked state
- **THEN** an error is returned and no child is stopped or migrated

### Requirement: Drain completion is observable
The system SHALL dispatch a hook when a drain completes, carrying the drain summary (migrated and forced child counts).

#### Scenario: Hook on completion
- **WHEN** a drain finishes (including deadline-forced completion)
- **THEN** the `drain_completed` hook is dispatched with the summary

### Requirement: Checkpointability guidance is documented
The documentation SHALL state that long-running processes should be checkpointable — `prepare_handover_state` should return resumable progress — so that deadline-forced migration during drain (and `max_defer_time` expiry) is lossless, and that consent is an optimization for choosing a better migration moment, not a correctness requirement. The documentation SHALL also warn that consent detection does not work for processes started through wrapper modules.

#### Scenario: Documentation present
- **WHEN** a user reads the migration strategy / drain documentation
- **THEN** it explains checkpointable handover state, the wrapper-module detection limitation, and the primary-only consent limitation

