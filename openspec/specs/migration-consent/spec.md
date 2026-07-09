# migration-consent Specification

## Purpose
TBD - created by archiving change migration-consent-and-drain. Update Purpose after archive.
## Requirements
### Requirement: Consent participation is opt-in and auto-detected
The system SHALL query migration consent only when the migration strategy has consent enabled AND the child's module (from the child spec `start` MFA) exports the consent marker function provided by the shared consent macro. Children that do not participate SHALL migrate immediately, identically to the behavior without the feature. When consent is disabled on the strategy, the migration code path SHALL perform no consent-related work (no messages, no module checks).

#### Scenario: Non-consent child migrates immediately
- **WHEN** consent is enabled on the strategy and a topology expansion selects a child whose module does not export the consent marker
- **THEN** the child is migrated immediately without receiving a consent query

#### Scenario: Feature disabled means unchanged path
- **WHEN** the migration strategy has consent disabled (default)
- **THEN** no consent queries are sent and no deferred list is maintained; migration behaves exactly as before this change

#### Scenario: Consent macro provides defaults
- **WHEN** a GenServer uses the shared consent macro without overriding the consent callback
- **THEN** it replies `:ready` to consent queries and migrates on the first attempt

### Requirement: Consent query gates migration on topology expansion
On topology expansion, for each consent-participating local child selected for migration, the system SHALL send a consent query to the child's local pid and wait for replies under a shared wall-clock deadline of `consent_timeout`. A `:ready` reply SHALL cause immediate migration through the existing migration path (including state handover when enabled). A `:defer` reply, or no reply within the deadline, SHALL add the child to the deferred-migration list instead of migrating it.

#### Scenario: Ready reply migrates now
- **WHEN** a consent-participating child replies `:ready` within `consent_timeout`
- **THEN** it is migrated in the same redistribution cycle via the existing HotSwap/ColdSwap path, with state handover unchanged

#### Scenario: Defer reply parks the child
- **WHEN** a consent-participating child replies `:defer`
- **THEN** it is not started on the target node, not terminated locally, and is added to the deferred list

#### Scenario: No reply counts as defer
- **WHEN** a consent-participating child does not reply within `consent_timeout`
- **THEN** it is treated as `:defer` and added to the deferred list

#### Scenario: Already-deferred child is not re-queried by topology events
- **WHEN** a new topology event selects a child that is already in the deferred list
- **THEN** no additional consent query is sent and no duplicate deferred entry is created

### Requirement: Deferred children are retried in batches
The system SHALL retry the deferred list in batches every `retry_interval`, scheduling the retry timer only while the list is non-empty. Each retry SHALL recompute target nodes from the current distribution, prune entries whose child no longer has a local pid or whose recomputed primary node is the local node, and migrate as a batch those children that signaled readiness, reply `:ready` to a re-query, or exceeded `max_defer_time`. The local node SHALL be terminated as part of the migration only when it is no longer any target node, so a replica instance is preserved.

#### Scenario: Deferred child migrates after signaling readiness
- **WHEN** a deferred child becomes ready and the next retry tick runs
- **THEN** it is migrated to its recomputed target node via the existing migration path and removed from the deferred list

#### Scenario: Targets recomputed at retry time
- **WHEN** the cluster topology changed between deferral and retry
- **THEN** the migration uses the target node computed at retry time, not the target from the original deferral

#### Scenario: Stale entries are pruned
- **WHEN** a deferred child has died, or the distribution now assigns it to the local node as primary
- **THEN** its entry is removed from the deferred list without migration

#### Scenario: Local node remains a replica target
- **WHEN** a deferred child's recomputed primary is a remote node while the local node stays a replica target
- **THEN** the child is migrated to the remote primary and its local instance is not terminated

#### Scenario: No timer when list is empty
- **WHEN** the deferred list becomes empty
- **THEN** no retry timer is scheduled until a new entry is added

### Requirement: Deferral expires after max_defer_time
The system SHALL force-migrate a deferred child once its time in the deferred list exceeds `max_defer_time` (default 600000 ms), using the existing best-effort state-query migration path, and SHALL log a warning identifying the forced child ids. Deferral expiry SHALL never be silent.

#### Scenario: Forced migration on expiry
- **WHEN** a deferred child has been deferred longer than `max_defer_time` at a retry tick
- **THEN** it is migrated without further consent, with state handover attempted via the existing state query, and a warning is logged

### Requirement: Processes can self-signal readiness
The system SHALL provide a public API function for marking a deferred child as ready for migration. The call SHALL mark the entry ready and ensure a retry tick is scheduled. Calling it for a child that is not in the deferred list SHALL return an error and change nothing.

#### Scenario: Readiness signal accepted
- **WHEN** `ProcessHub.migration_ready(hub_id, child_id)` is called for a deferred child
- **THEN** the entry is marked ready and the child is migrated on the next retry tick

#### Scenario: Unknown child rejected
- **WHEN** `ProcessHub.migration_ready(hub_id, child_id)` is called for a child not in the deferred list
- **THEN** `{:error, :not_deferred}` is returned and no state changes

### Requirement: Consent applies to primary instances only
The consent protocol SHALL apply only to migrations performed by the migration strategy (the primary instance). Replica placement performed by the Replication strategy SHALL be unaffected, and this limitation SHALL be documented.

#### Scenario: Replicas move without consent
- **WHEN** the Replication strategy re-homes replica instances during redistribution
- **THEN** no consent queries are sent for those replica moves

### Requirement: Deferral events are observable
The system SHALL dispatch a hook when children are added to the deferred list, carrying the affected child ids.

#### Scenario: Hook on deferral
- **WHEN** one or more children are deferred during a redistribution
- **THEN** the `migration_deferred` hook is dispatched with those child ids

