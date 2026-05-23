# cluster-leadership Specification

## Purpose
TBD - created by archiving change cluster-leadership-and-migration. Update Purpose after archive.
## Requirements
### Requirement: Leadership SHALL be opt-in and never started by default

ProcessHub SHALL NOT start the `:elector` application (and therefore Erlang `:global`) by
default. Leadership SHALL be started only when (a) the user explicitly calls
`ProcessHub.start_leadership/0`, or (b) a distribution strategy that requires it
(`CentralizedLoadBalancer`) starts it. `ProcessHub.stop_leadership/0` SHALL stop the local
elector instance. The logic SHALL live in `ProcessHub.Service.Leadership`; `ProcessHub`
SHALL expose only thin delegators.

#### Scenario: A hub with a non-elector strategy does not start :global
- **GIVEN** a hub using `ConsistentHashing` and a user who never calls `start_leadership/0`
- **WHEN** the hub starts and runs
- **THEN** the `:elector` application SHALL NOT be started and `:global` SHALL NOT be required by ProcessHub

#### Scenario: Explicit opt-in starts leadership
- **WHEN** the user calls `ProcessHub.start_leadership/0`
- **THEN** the local elector instance SHALL be started
- **AND** a subsequent `ProcessHub.stop_leadership/0` SHALL stop it

### Requirement: Leader query SHALL NOT auto-start leadership

`ProcessHub.leader/0` SHALL return `{:ok, node()}` for the current leader, or
`{:error, :leadership_not_started}` when leadership has not been started. `is_leader?/0`
SHALL return whether the local node is the leader (`false` when leadership is not started).
Neither SHALL start `:elector` as a side effect. Both SHALL work whether leadership was
started via `start_leadership/0` or by a distribution strategy.

#### Scenario: Query before leadership is started
- **GIVEN** leadership has not been started
- **WHEN** `ProcessHub.leader/0` is called
- **THEN** it SHALL return `{:error, :leadership_not_started}` and SHALL NOT start `:elector`
- **AND** `ProcessHub.is_leader?/0` SHALL return `false`

#### Scenario: Query after leadership is started
- **GIVEN** `start_leadership/0` has been called on a single-node cluster
- **WHEN** `ProcessHub.leader/0` is called
- **THEN** it SHALL return `{:ok, node()}` with the local node
- **AND** `ProcessHub.is_leader?/0` SHALL return `true`

### Requirement: Leadership changes SHALL be observable via subscription

ProcessHub SHALL let a process subscribe to leadership changes and receive a message when
the leader changes (including the initial election). The notification SHALL carry the new
leader, the previous leader, and whether the local node is now the leader. Detection SHALL
be event-driven off cluster-membership changes (no busy polling). Subscription is a service-
level capability (`ProcessHub.Service.Leadership.subscribe/1` / `unsubscribe/1`); it is not
part of the curated public `ProcessHub` API.

#### Scenario: Subscriber is notified on a leadership change
- **GIVEN** a process subscribed via `ProcessHub.Service.Leadership.subscribe/0`
- **WHEN** the elected leader changes
- **THEN** the subscriber SHALL receive a message identifying the new leader, the previous leader, and `am_i_leader`

### Requirement: Leadership transitions SHALL emit telemetry

ProcessHub SHALL emit a `:telemetry` event on each leadership transition carrying the new
leader, previous leader, and local-node leadership status, so operators can observe
leadership without subscribing.

#### Scenario: Telemetry on transition
- **WHEN** the leader changes
- **THEN** a `[:process_hub, :leadership, :changed]` telemetry event SHALL be emitted with the leader, previous, and `am_i_leader` in its metadata

### Requirement: Stopping leadership SHALL step down gracefully

`ProcessHub.stop_leadership/0` SHALL trigger a clean leadership step-down so a successor is
elected promptly (rather than waiting for a node-down timeout), enabling zero-downtime
rolling restarts of the leader node.

#### Scenario: Step-down hands leadership over promptly
- **GIVEN** a multi-node cluster whose local node is the leader
- **WHEN** `ProcessHub.stop_leadership/0` is called on the leader node
- **THEN** a new leader SHALL be elected among the remaining nodes without waiting for a `nodedown` timeout

### Requirement: `on_leader/1` SHALL run a function only on the leader

`ProcessHub.on_leader/1` SHALL evaluate the supplied zero-arity function only if the local
node is the leader, returning the function's result, and SHALL otherwise return a
not-leader indication without evaluating it.

#### Scenario: Runs on the leader, skips elsewhere
- **GIVEN** leadership is started
- **WHEN** `ProcessHub.on_leader(fun)` is called on the leader node
- **THEN** `fun` SHALL be evaluated and its result returned
- **AND** when called on a non-leader node `fun` SHALL NOT be evaluated

