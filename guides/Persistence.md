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

## Coordinator recovery

When a returning node holds a persisted registry, naively re-asserting
those rows on boot would either resurrect children the cluster has
already redistributed or duplicate children running on peers. The
opt-in **coordinator recovery** lifecycle gives the coordinator a
"wait and see" phase so it can defer to peers when they hold
authoritative state.

### The three states

The coordinator's `:recovery_state` is one of:

  * **`:recovery_pending`** — initial state when `:auto_recovery` is
    enabled. The coordinator is gathering peer information to decide
    whether to replay locally.
  * **`:recovering`** — actively iterating the persisted registry and
    dispatching `start_children` calls.
  * **`:normal`** — fully operational. Reachable from
    `:recovery_pending` (deferred-to-peers path) or from `:recovering`
    (replay completed or timed out).

When `:auto_recovery` is `false` (the default), `:recovery_state` is
`:normal` from `init/1` and never transitions — preserving every bit
of pre-existing behaviour.

### Configuration

```elixir
%ProcessHub{
  hub_id: :my_hub,
  registry_backend: {:dets, []},
  auto_recovery: [
    recovery_window_ms: 10_000,
    replay_timeout_ms: 60_000
  ]
}
```

Accepted shapes:

  * `false` (default) — disabled.
  * `true` — enabled with default window and timeout.
  * `keyword()` — explicit:
    * `:recovery_window_ms` — default `10_000`, range
      `[1_000, 600_000]`.
    * `:replay_timeout_ms` — default `60_000`, range
      `[1_000, 3_600_000]`.

Out-of-range values cause the coordinator to refuse to start with
`{:invalid_auto_recovery, _}`.

### Peer handshake

While in `:recovery_pending`, on receipt of `@event_cluster_join` for a
new peer, the coordinator dispatches `@event_recovery_state_query` to
that peer. The peer responds with `@event_recovery_state_announce`
carrying its current state.

  * If any peer reports `:normal`, the coordinator cancels the window
    timer and transitions directly to `:normal` (skip replay; the
    existing synchronization strategy populates the local registry
    from peers).
  * If the window elapses without a `:normal` peer, the coordinator
    transitions to `:recovering`, replays its persisted registry via
    `Distributor.compose_start_operation/3`, then transitions to
    `:normal`.

Old ProcessHub versions silently drop the new events (no handler
registered) — mixed-version clusters function correctly.

### Hooks

Three new hooks (see `ProcessHub.Constant.Hook`) cover the lifecycle:

  * `recovery_state_changed/0` — fires on every transition (async).
    Payload: `%{from: state, to: state, reason: atom(),
    peers: %{node => state}}`.
  * `pre_recovery_replay/0` — fires once when entering `:recovering`,
    before any `start_children` is dispatched. **Synchronous** — the
    coordinator awaits each handler's reply. Use for prerequisite
    services (e.g. wait until a downstream FleetManager is ready).
    Handlers are wrapped in `try/catch` with a per-handler timeout
    derived from `:replay_timeout_ms`; crashes are logged and the
    lifecycle proceeds.
  * `post_recovery_replay/0` — fires once when leaving `:recovering`
    (async). Use to mark "boot complete."

### Public API

```elixir
ProcessHub.recovery_state(:my_hub)
# => :recovery_pending | :recovering | :normal

ProcessHub.await_normal(:my_hub, 30_000)
# => :ok | {:error, :timeout}
```

For hubs without `:auto_recovery`, both functions report `:normal` /
`:ok` immediately.

### Telemetry

Two events are emitted from the replay path:

  * `[:process_hub, :coordinator, :recovery_replay_started]`
    — measurements `%{child_count: N}`, metadata `%{hub_id: id}`.
  * `[:process_hub, :coordinator, :recovery_replay_completed]`
    — measurements `%{child_count: N, succeeded: S, failed: F,
    elapsed_ms: T}`, metadata `%{hub_id: id, reason: atom()}`. The
    `reason` is `:completed`, `:replay_timeout`, or `:empty`.

### Recommended pairing

`auto_recovery: true` is most useful with a persistent registry
backend such as `registry_backend: {:dets, []}`. With the default
`:ets` backend, the registry is empty on every restart — the coord-
inator transitions through `:recovering` with zero rows to replay and
immediately reaches `:normal`. The combination is permitted but does
not provide restart-survival; documentation calls this out so opera-
tors do not assume otherwise.
