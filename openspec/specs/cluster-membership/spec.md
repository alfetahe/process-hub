# cluster-membership Specification

## Purpose
Bounded, debounce-safe processing of cluster-membership events (join/leave) so a hub always
forms its cluster within a bounded time — even under a sustained event stream that would
otherwise starve the per-event debounce — and surfaces suboptimal debounce/discovery
configuration without rejecting startup.

## Requirements
### Requirement: Cluster-membership discovery SHALL converge within a bounded time

The coordinator SHALL process a batched cluster-membership event (join/leave) within a
bounded maximum wait, even under a sustained stream of events arriving faster than the
`:cluster_event_debounce` window, so membership discovery is never starved. Configuring
`:hubs_discover_interval` at or below `:cluster_event_debounce` SHALL NOT prevent a hub from
forming its cluster.

#### Scenario: Fast discovery interval still clusters

- **GIVEN** two nodes running the same hub configured with `:hubs_discover_interval` less than or equal to `:cluster_event_debounce`
- **WHEN** the nodes discover each other
- **THEN** each node's hub SHALL converge to a cluster containing both nodes (the batched join is flushed within the bounded max wait, not starved)

#### Scenario: Sustained join stream is still processed

- **GIVEN** a coordinator receiving `cluster_join` events spaced closer together than `:cluster_event_debounce`
- **WHEN** the events keep arriving
- **THEN** the pending batch SHALL be processed within the bounded maximum wait rather than being deferred indefinitely

### Requirement: Conflicting debounce/discovery configuration SHALL be surfaced

ProcessHub SHALL log a warning at startup when a hub is configured with
`:cluster_event_debounce` greater than or equal to `:hubs_discover_interval` — a suboptimal
configuration that the bounded max wait now tolerates but does not endorse — and SHALL still
start and cluster the hub normally.

#### Scenario: Warning on suboptimal configuration

- **GIVEN** a hub configured with `:cluster_event_debounce` greater than or equal to `:hubs_discover_interval`
- **WHEN** the hub starts
- **THEN** a warning identifying the conflicting settings SHALL be logged
- **AND** the hub SHALL start and cluster normally
