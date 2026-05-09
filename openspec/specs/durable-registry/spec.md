# durable-registry Specification

## Purpose

TBD - created from the durable-registry change. Update Purpose after the change is archived.

## Requirements

### Requirement: Pluggable storage backend behaviour for the process registry

ProcessHub SHALL define a behaviour `ProcessHub.Service.Storage.Behaviour` declaring the contract for registry-table storage operations. The behaviour SHALL specify the following callbacks:

- `open(hub_id :: atom(), opts :: keyword()) :: {:ok, ref()} | {:error, term()}`
- `close(ref :: term()) :: :ok`
- `insert(ref :: term(), key :: term(), value :: term()) :: :ok | {:error, term()}`
- `insert(ref :: term(), key :: term(), value :: term(), opts :: keyword()) :: :ok | {:error, term()}` — opts MAY include `:ttl` (milliseconds)
- `get(ref :: term(), key :: term()) :: term() | nil`
- `exists?(ref :: term(), key :: term()) :: boolean()`
- `remove(ref :: term(), key :: term()) :: :ok | {:error, term()}`
- `export_all(ref :: term()) :: list()`
- `foldl(ref :: term(), acc :: term(), fun :: (term(), term() -> term())) :: term()`
- `match(ref :: term(), match_expr :: term()) :: list()`
- `clear_all(ref :: term()) :: :ok`

The `ref()` type is opaque to callers; each backend implementation SHALL define its own representation (ETS tid, DETS table name, custom client handle, etc.).

All mutating callbacks SHALL return `:ok | {:error, term()}` rather than booleans, to accommodate backends that may fail synchronously (timeout, no quorum, IO error) — including hypothetical future replicated backends.

#### Scenario: Behaviour module is defined and loadable

- **WHEN** `Code.ensure_loaded?(ProcessHub.Service.Storage.Behaviour)` is called
- **THEN** it returns `true`
- **AND** `ProcessHub.Service.Storage.Behaviour.behaviour_info(:callbacks)` returns the list above

### Requirement: ETS backend implementation preserves current Storage behaviour

ProcessHub SHALL provide `ProcessHub.Service.Storage.Ets` implementing `ProcessHub.Service.Storage.Behaviour`. The ETS backend SHALL exhibit bit-for-bit identical observable behaviour to the current `ProcessHub.Service.Storage` module, including:

- TTL semantics (entries inserted with `ttl: N` are stored as `{key, value, expire_ms}` and queried with awareness of expiration).
- Concurrent-read semantics (ETS public/protected access patterns preserved).
- Match-expression behaviour matching the current `Storage.match/2`.
- Foldl semantics matching the current `Storage.foldl/3`.

The existing public API of `ProcessHub.Service.Storage` SHALL remain unchanged. Internally, `Storage` SHALL delegate registry-table operations through the configured backend (default `:ets` → `Storage.Ets`); misc and hook storage continue using ETS directly without backend dispatch.

#### Scenario: Existing call sites work unchanged

- **GIVEN** an existing application using `ProcessHub.Service.Storage.insert(table, :key, "value")` with default `registry_backend`
- **WHEN** the call is made
- **THEN** the value is stored exactly as in the pre-change behaviour and `ProcessHub.Service.Storage.get(table, :key)` returns `"value"`

#### Scenario: TTL semantics preserved

- **WHEN** `Storage.Ets.insert(ref, :key, "value", ttl: 100)` is called and 200 ms passes
- **THEN** `Storage.Ets.get(ref, :key)` SHALL return `nil` (or the existing TTL behaviour the current `Storage` exhibits, whichever is bit-for-bit identical)

### Requirement: DETS backend implementation provides on-disk persistence

ProcessHub SHALL provide `ProcessHub.Service.Storage.Dets` implementing `ProcessHub.Service.Storage.Behaviour` with on-disk persistence via OTP `:dets`.

`open/2` SHALL:

1. Resolve the file path: from `opts[:path]` if provided, else default `priv/process_hub/<hub_id>/registry.dets` resolved against the application's `priv` directory.
2. Ensure the parent directory exists (`File.mkdir_p!/1`).
3. Call `:dets.open_file/2` with options `[file: path, repair: true, type: :set]`.
4. If `:dets.open_file/2` returns `{:error, _}` indicating an unrepairable corrupt file: rename the file to `<path>.corrupt-<System.monotonic_time()>`, emit `[:process_hub, :registry, :backend_corrupt]` telemetry with `%{path: <path>, rotated_to: <new_path>, reason: <reason>}`, and open a fresh empty DETS at the original path.
5. Return `{:ok, table_name}` on success, where `table_name` is the atom returned by `:dets.open_file/2`.
6. Emit `[:process_hub, :registry, :backend_opened]` telemetry with `%{path: <path>, row_count: N, repaired: bool}`.

Every mutator (`insert/3`, `insert/4`, `remove/2`, `clear_all/1`) SHALL call `:dets.sync/1` before returning. This guarantees that any operation observed by the caller as `:ok` is durable on disk.

`close/1` SHALL call `:dets.close/1` (which itself performs a final sync).

`export_all/1` SHALL be implemented via `:dets.foldl/3` accumulating into a list (matching the existing ETS `tab2list` shape but with TTL-expired entries filtered out, mirroring ETS-backend behaviour).

TTL emulation: DETS has no native TTL. Entries inserted with `:ttl` SHALL be stored as `{key, value, expire_ms}` (matching the ETS layout). Reads SHALL filter expired entries on the way out. A periodic TTL sweeper is OUT OF SCOPE for this change; expired entries accumulate until manually swept (acceptable because TTL usage on the registry is rare and bounded).

#### Scenario: DETS open creates the file on first use

- **GIVEN** no file exists at `priv/process_hub/<hub_id>/registry.dets`
- **WHEN** `Storage.Dets.open(:my_hub, [])` is called
- **THEN** the parent directory is created if needed; a fresh empty DETS file is created; the function returns `{:ok, table_name}`
- **AND** `[:process_hub, :registry, :backend_opened]` telemetry fires with `%{row_count: 0, repaired: false}`

#### Scenario: DETS reopens existing file with state preserved

- **GIVEN** a DETS file at the expected path containing 5 rows from a prior session
- **WHEN** `Storage.Dets.open/2` is called
- **THEN** the file is opened; `Storage.Dets.export_all/1` returns 5 rows; telemetry's `row_count` is 5

#### Scenario: DETS sync after every mutation

- **WHEN** `Storage.Dets.insert(ref, :key, "value")` returns `:ok`
- **THEN** the value is durable on disk such that a subsequent process crash + restart finds the value present in `Storage.Dets.export_all/1`

#### Scenario: Corrupt DETS file is rotated and a fresh file opened

- **GIVEN** a DETS file at the path is corrupt and `:dets.open_file/2` with `repair: true` returns `{:error, _reason}` even after attempting repair
- **WHEN** `Storage.Dets.open/2` is called
- **THEN** the corrupt file is renamed to `<path>.corrupt-<monotonic>`; a fresh empty DETS file is created at the original path; `[:process_hub, :registry, :backend_corrupt]` telemetry fires with the rotated path; `Storage.Dets.open/2` returns `{:ok, table_name}`

### Requirement: `:registry_backend` configuration field with `:ets` default

`ProcessHub.t()` SHALL include a new optional field `:registry_backend` accepting these shapes:

- `:ets` — use `ProcessHub.Service.Storage.Ets`. THIS IS THE DEFAULT and matches all existing behaviour.
- `{:dets, opts}` where `opts` is `keyword()` — use `ProcessHub.Service.Storage.Dets`. Recognised opts: `path: String.t()` (file path; defaults to `priv/process_hub/<hub_id>/registry.dets`).
- `{Module, opts}` where `Module` implements `ProcessHub.Service.Storage.Behaviour` — use the custom module. Allows downstream extensibility (in-memory test backends, future Raft backend, etc.).

`ProcessHub.Coordinator.init/1` SHALL open the configured backend before the supervision tree completes setup, store the returned `ref()` in the `Hub.t()` storage map, and pass it to all registry-touching code paths. `terminate/2` SHALL call `Backend.close/1`.

The existing fields `:distribution_strategy`, `:synchronization_strategy`, `:migration_strategy`, `:redundancy_strategy`, `:partition_tolerance_strategy` and all other configuration are unchanged.

#### Scenario: Default config is `:ets`

- **GIVEN** an application creates a hub with `ProcessHub.child_spec(%ProcessHub{hub_id: :h1, ...})` and does not set `:registry_backend`
- **WHEN** the hub starts
- **THEN** the registry uses `Storage.Ets`; behaviour is bit-for-bit identical to pre-change ProcessHub
- **AND** no DETS file is created on disk

#### Scenario: Opt-in DETS persistence

- **GIVEN** a hub configured with `registry_backend: {:dets, path: "/tmp/myhub.dets"}`
- **WHEN** the hub starts and a child is registered
- **THEN** the registry row is durably stored at `/tmp/myhub.dets`
- **WHEN** the coordinator process is killed and restarted
- **THEN** the new coordinator's registry contains the row that was registered before the kill

#### Scenario: Custom backend module accepted

- **GIVEN** a hub configured with `registry_backend: {MyApp.MockStorage, []}` where `MyApp.MockStorage` implements `ProcessHub.Service.Storage.Behaviour`
- **WHEN** the hub starts
- **THEN** registry operations dispatch through `MyApp.MockStorage`; no error is raised

### Requirement: Telemetry events for registry-backend lifecycle and operations

The DETS and any future backend SHALL emit telemetry. The ETS backend MAY emit telemetry for parity but it is NOT required (zero-cost ETS path is preferred).

Required events emitted by the backend wrapper layer (the layer between `ProcessHub.Service.ProcessRegistry` and the configured backend):

- `[:process_hub, :registry, :backend_opened]` with `%{row_count: N, elapsed_ms: T}` measurement and `%{hub_id: id, backend: module, path: nil_or_path, repaired: bool}` metadata.
- `[:process_hub, :registry, :backend_corrupt]` (DETS only) with `%{}` measurement and `%{hub_id: id, path: <orig>, rotated_to: <new>, reason: term}` metadata.
- `[:process_hub, :registry, :insert]` with `%{count: 1}` measurement and `%{hub_id: id, child_id: term}` metadata. Emitted on every successful insert.
- `[:process_hub, :registry, :remove]` with `%{count: 1}` and `%{hub_id: id, child_id: term}`. Emitted on every successful remove.

Existing ProcessHub telemetry events are unchanged.

#### Scenario: Backend opened event fires once per hub start

- **WHEN** a hub starts with `registry_backend: {:dets, []}`
- **THEN** exactly one `[:process_hub, :registry, :backend_opened]` event fires with `backend: ProcessHub.Service.Storage.Dets`

#### Scenario: Insert/remove telemetry on every registry mutation

- **GIVEN** an attached telemetry handler subscribed to `[:process_hub, :registry, :insert]`
- **WHEN** `ProcessRegistry.insert(hub_id, child_spec, nodes_pids, ...)` is called
- **THEN** the handler receives the event with the correct `child_id` in metadata

### Requirement: Backward compatibility — existing applications need no changes

Applications using ProcessHub before this change SHALL NOT require any code modification, configuration change, dependency update, or migration step to continue functioning identically after this change is merged.

Specifically:

- The `ProcessHub.t()` struct accepts the new field as `nil`/absent and treats it as `:ets`.
- `ProcessHub.Service.Storage`'s public API surface is unchanged.
- `ProcessHub.Service.ProcessRegistry`'s public API surface is unchanged.
- All existing strategy structs, hooks, and configuration keys behave identically.
- No new required runtime dependencies (uses OTP `:dets` only when opted in).
- No mandatory database, filesystem, or environment setup.

#### Scenario: Pre-change application unmodified after upgrade

- **GIVEN** an application's `mix.exs` and `config/*.exs` are unchanged from before this change
- **WHEN** the application is rebuilt against the post-change ProcessHub
- **THEN** all existing tests pass; no DETS files are created; runtime behaviour is bit-for-bit identical to pre-change

#### Scenario: Existing public Storage API unchanged

- **WHEN** any pre-existing call to `ProcessHub.Service.Storage.insert/3`, `Storage.get/2`, `Storage.exists?/2`, `Storage.update/3`, `Storage.remove/2`, `Storage.export_all/1`, `Storage.foldl/3`, `Storage.match/2`, or `Storage.clear_all/1` is made
- **THEN** the function signature, return value, and side effects are identical to pre-change behaviour
