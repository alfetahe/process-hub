# coordinator-responsiveness Specification

## Purpose

The coordinator is a hub's one serialising process. This capability keeps it answering:
other processes read a hub's fixed parts without asking it, it never waits on another
process's slow work, a failing worker-queue job costs only itself, and a coordinator
restart keeps the hub's storage.
## Requirements
### Requirement: Any process reads a running hub without calling the coordinator

A hub's fixed parts, `hub_id`, `procs`, `storage` and `recovery_config`, SHALL be held
in `%ProcessHub.Hub{}` and stored where any process can read them by hub id.
`ProcessHub.Hub.get/1` SHALL return that struct for a running hub, and `nil` for a hub
that is not running, without sending a message to the coordinator.

The hub SHALL be stored before any of its processes start, and SHALL be removed when the
hub stops. `ProcessHub.Hub.put/1` SHALL be the only way to write it. If the coordinator
ever changes its copy of these fields, it SHALL write the new value through `put/1` in
the same step.

The coordinator's bookkeeping, meaning every field that changes after start, SHALL NOT
be part of `%ProcessHub.Hub{}`. It SHALL be held in the coordinator's own state, and
read from outside only through a call that asks the coordinator for that one answer, such
as `ProcessHub.is_locked?/1`.

#### Scenario: Reading the hub while the coordinator is busy

- **GIVEN** a running hub whose coordinator is suspended
- **WHEN** another process calls `ProcessHub.Hub.get(hub_id)`
- **THEN** it receives the hub's `hub_id`, `procs`, `storage` and `recovery_config`
  immediately

#### Scenario: A hub that is not running

- **WHEN** a process calls `ProcessHub.Hub.get(:no_such_hub)`
- **THEN** it receives `nil` and no exit is raised

#### Scenario: A stopped hub is no longer readable

- **GIVEN** a running hub
- **WHEN** the hub is stopped with `ProcessHub.stop/1`
- **THEN** `ProcessHub.Hub.get(hub_id)` returns `nil`

### Requirement: The coordinator does not wait on another process's slow work

The coordinator SHALL NOT wait inside a message handler for work whose duration depends
on another process or node. Specifically:

- merging a peer's registry broadcast SHALL run in the hub's worker queue, and the peer's
  registry data SHALL count as delivered once that merge has completed;
- a durable command on a node that is not the declared-list leader SHALL wait for the
  leader in a separate process, and the coordinator SHALL answer the command's caller
  once the leader has acknowledged. The mutation SHALL still commit before the child is
  started or stopped;
- re-fetching the remote manifest SHALL run in a separate process, and the result SHALL
  be applied by the coordinator after any declared-list batch in flight has been written.

While any of these is in progress, the coordinator SHALL keep handling other messages.

#### Scenario: A slow registry does not stall or crash the coordinator

- **GIVEN** a running hub whose process registry is suspended
- **WHEN** the coordinator receives a peer's registry broadcast
- **THEN** the coordinator answers a call within 1 s
- **AND** the coordinator does not stop

#### Scenario: A follower keeps answering while the leader is busy

- **GIVEN** a two-node cluster running a hub with `:auto_recovery`, and the declared-list
  leader's coordinator is suspended
- **WHEN** a child is started with `durable: true` on the other node
- **THEN** that node's coordinator answers a call within 1 s
- **AND** the start is answered only after the leader has acknowledged the mutation

#### Scenario: A hanging manifest store does not stall the coordinator

- **GIVEN** a hub with `:auto_recovery` whose `:remote_manifest` adapter's `fetch/2`
  does not return
- **WHEN** the coordinator re-fetches the remote manifest
- **THEN** the coordinator answers a call within 1 s

### Requirement: One failing job costs only that job

A job in the worker queue that raises, exits or throws SHALL be logged at ERROR with the
job's kind and the reason, and the worker queue SHALL go on to the next job. A job the
coordinator counted out SHALL be reported done whether it succeeded or failed, so the
count behind `ProcessHub.is_locked?/1` always returns to zero once the queue is empty.

#### Scenario: The queue survives a job that cannot reach the coordinator

- **GIVEN** a peer's sync job, the coordinator's own tracked job and a further job queued
  in that order, with the coordinator suspended
- **WHEN** the queue processes them
- **THEN** the worker queue process is still the same process afterwards
- **AND** the further job has run

#### Scenario: The hub is not left locked

- **GIVEN** the same queue, after the coordinator resumes
- **WHEN** the queue is empty
- **THEN** `ProcessHub.is_locked?(hub_id)` returns `false`

### Requirement: A coordinator restart keeps the hub's storage

A coordinator restart SHALL NOT close the hub's storage. The registry backend, the
declared-list store and the stored `%ProcessHub.Hub{}` SHALL be closed or removed only
when the hub stops (`:normal`, `:shutdown` or `{:shutdown, term}`). When the coordinator
crashes, the restarted coordinator SHALL use the same open storage.

#### Scenario: The registry works after a coordinator crash

- **GIVEN** a running hub with a registered child
- **WHEN** its coordinator crashes and is restarted by the supervisor
- **THEN** the child registered before the crash is still found
- **AND** a new child can be registered and looked up

