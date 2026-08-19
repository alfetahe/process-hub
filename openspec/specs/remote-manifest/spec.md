# remote-manifest Specification

## Purpose
An off-cluster copy of the declared list behind a pluggable adapter behaviour:
shipped asynchronously by the hub leader after every mutation and consulted on
boot, so the list survives the loss of every cluster disk. A backup consulted
at the edges, never a synchronous dependency of any command. Experimental.
## Requirements
### Requirement: A pluggable behaviour defines off-cluster manifest storage

ProcessHub SHALL define `ProcessHub.Storage.RemoteManifest` with callbacks:

- `store(hub_id :: atom(), version :: pos_integer(), blob :: binary(), opts :: keyword()) :: :ok | {:error, term()}`
- `fetch(hub_id :: atom(), opts :: keyword()) :: {:ok, {version :: pos_integer(), blob :: binary()}} | :not_found | {:error, term()}`
- `info(opts :: keyword()) :: map()`

A hub SHALL accept `remote_manifest: {module, opts}` inside its
`:auto_recovery` options; the default (absent) disables the remote layer
with zero behaviour change. `store/4` SHALL NOT overwrite a stored copy
whose version is higher than the one being written, on backends that can
express the check.

#### Scenario: Behaviour is defined and configurable

- **WHEN** a hub is configured with
  `auto_recovery: [remote_manifest: {MyAdapter, opts}]` where `MyAdapter`
  implements the behaviour
- **THEN** the hub starts and uses the adapter for shipping and boot fetch

#### Scenario: Stale writer cannot clobber a newer copy

- **GIVEN** a backend supporting conditional writes holding version 50
- **WHEN** a stale leader ships version 48
- **THEN** the stored copy remains version 50

### Requirement: The leader ships every mutation without blocking commands

After a declared-list mutation commits, the leader SHALL ship the newest
list and version to the configured adapter asynchronously, retrying with
backoff and coalescing superseded versions. A failing or slow adapter SHALL
NOT fail, delay, or reorder the originating start/stop command. Shipping
failures SHALL emit telemetry. Non-leader nodes SHALL NOT ship.

#### Scenario: Adapter outage does not affect commands

- **GIVEN** a configured adapter whose `store/4` returns errors
- **WHEN** declared children are started and stopped
- **THEN** every command succeeds locally, telemetry reports the failed
  ships, and when the adapter recovers the latest list version reaches it

### Requirement: Boot consults the remote copy and the higher version wins

On boot with a remote manifest configured, the hub SHALL fetch the remote
copy before the first reconcile round and compare versions with the local
list: the higher version SHALL be adopted, whichever side holds it. A
missing or corrupt local list SHALL be restored wholly from the remote copy.

#### Scenario: Lost local disks restore from the remote

- **GIVEN** a stop committed at list version 42 and shipped remotely, after
  which every cluster disk holding version 42 is lost, and node B returns
  alone with a stale local list at version 37
- **WHEN** B boots and fetches the remote manifest
- **THEN** B adopts version 42, does not start the stopped child, and starts
  the children version 42 declares

#### Scenario: Stale remote does not override a newer local list

- **GIVEN** a local list at version 50 and a remote copy at version 48
  (ship retries still in flight)
- **WHEN** the hub boots
- **THEN** the local version 50 is kept and shipped, and the remote copy
  converges to 50

### Requirement: Built-in adapters are LocalPath and S3, behind one contract

ProcessHub SHALL provide a `LocalPath` adapter (filesystem path, no external
dependency, atomic replace writes) and an `S3` adapter using conditional
writes, compiled and loadable only when its optional dependency is present;
its absence SHALL NOT affect core compilation, and configuring an
unavailable adapter SHALL fail at hub start with a clear error naming the
missing dependency. Both adapters, and the behaviour itself, SHALL be
covered by one shared public contract test suite; core CI SHALL run it
against `LocalPath`. `LocalPath` documentation SHALL state that the path
must live off-cluster to protect against whole-cluster loss.

#### Scenario: Core builds without the S3 dependency

- **WHEN** ProcessHub is compiled in a project without the optional S3
  dependency
- **THEN** compilation succeeds, `LocalPath` is usable, and configuring the
  S3 adapter fails at hub start with an error naming the missing dependency

