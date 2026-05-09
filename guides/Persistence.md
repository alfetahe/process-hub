# Persistence

By default ProcessHub keeps its per-coordinator process registry in an
in-memory ETS table. When the coordinator restarts, the registry is
rebuilt from peers via the configured synchronization strategy. A node
that returns into a cluster of `:bootstrap`-state peers, or restarts as
a sole survivor, has no record of the children it was hosting.

For workloads that need restart-survival on a single node, ProcessHub
supports an opt-in **DETS**-backed registry. This is configured via the
`:registry_backend` field on `%ProcessHub{}`.

## Backends

`:registry_backend` accepts these shapes:

- `:ets` — *(default)* in-memory ETS. Identical to all prior behaviour.
  Existing applications need no changes.
- `{:dets, opts}` — on-disk persistence via `:dets`. Recognised opts:
  - `path: String.t()` — file path. Defaults to
    `priv/process_hub/<hub_id>/registry.dets`.
- `{Module, opts}` — a custom module implementing
  `ProcessHub.Service.Storage.Behaviour`. Useful for an in-memory test
  backend or any external store you want to plug in.

```elixir
ProcessHub.child_spec(%ProcessHub{
  hub_id: :my_hub,
  registry_backend: {:dets, path: "/var/lib/myapp/hub.dets"}
})
```

## Recovery semantics on corruption

The DETS backend opens its file with `repair: true`. If
`:dets.open_file/2` still returns `{:error, _}` (unrecoverable
corruption), the file is rotated:

- The corrupt file is renamed to `<path>.corrupt-<system_monotonic>`.
- A `[:process_hub, :registry, :backend_corrupt]` telemetry event is
  emitted with `%{path: <orig>, rotated_to: <rotated>, reason: term}`.
- A fresh empty DETS file is opened at the original path. The hub
  starts with an empty local registry; cluster-wide state is rebuilt
  via the synchronization strategy.

This matches the operational pattern of refusing to fail-stop on
corruption: the system continues to run, the corrupt artefact is
preserved for forensics, and an alerting hook can listen on the
telemetry event.

## Telemetry events

The DETS backend emits the following events:

- `[:process_hub, :registry, :backend_opened]` —
  `%{row_count: N, elapsed_ms: T}` /
  `%{hub_id, backend, path, repaired: bool}`. Fired once per hub start.
- `[:process_hub, :registry, :backend_corrupt]` (DETS only) — fired
  when the file was rotated.
- `[:process_hub, :registry, :insert]` — `%{count: 1}` /
  `%{hub_id, child_id}`. Fired on every successful insert.
- `[:process_hub, :registry, :remove]` — `%{count: 1}` /
  `%{hub_id, child_id}`. Fired on every successful remove.

The default ETS backend does NOT emit these events (zero-cost path).

## Operational profile

Each registry mutation calls `:dets.sync/1` before returning. This
guarantees that any operation observed as `:ok` is durable on disk. On
local SSD this typically adds ~1–5 ms of latency per write; on slower
disks it can be more. Workloads with very high registry mutation rates
should keep the default `:ets` backend.

DETS does not compact automatically — deleted entries leave gaps in
the file. The registry is bounded by the number of children, so this
is usually negligible. Periodic compaction via `:dets.repair/1` is an
operator concern.

## TTL semantics

DETS has no native TTL. Entries inserted with a `:ttl` are stored as
`{key, value, expire_ms}` (matching the ETS layout). Reads filter
expired entries on the way out. A periodic sweeper for expired
entries is out of scope; expired rows accumulate until manually swept.
TTL usage on the registry is rare and bounded.

## Custom backends

Implement `ProcessHub.Service.Storage.Behaviour` and pass
`registry_backend: {MyModule, opts}`. Backends that may fail
synchronously (timeout, no quorum, IO error) can return
`{:error, reason}` from any mutating callback — the API is shaped so
that a future replicated backend (Raft, etc.) can plug in without
breaking existing call sites.
