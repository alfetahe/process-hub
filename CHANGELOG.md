# Change Log
All notable changes to this project will be documented in this file.

## v0.2.2-alpha - YYYY-MM-DD
Fixed:
- Replication master node could differ from node to node in some cases.

## v0.2.1-alpha - 2024-02-15
This release adds some guides and documentation pages and minor documentation fixes.

## v0.2.0-alpha - 2024-02-09
This release brings in lots of improvements and few new features.

The main focus was on making the distribution strategy configurable.
This has led to the introduction of new strategies and the ability to implement custom strategies
for process distribution.

Secondary focus was on improving the performance and reliability of the system.
Profiled and optimized the codebase to find the biggest inefficiencies and bottlenecks.

Includes also some bugfixes.

New guides and documentation pages added.

### Changed
- `Hook.registry_pid_inserted/0` no longer returns all node-pid pairs that are
inserted but only the ones that are different from the previous state.
This gives better overview of the changes that are made to the registry.
- Integration tests now take into account the replication factor when waiting
for the hook messages.
- Moved `belongs_to`function from redundancy to distribution strategy.
- Replication strategy is now selecting the active nodes with different algorithm.
- Hooks are no longer spawing new processes and are executed in the context of
the caller.
- Removed `cluster_nodes` parameter from `ProcessHub.Strategy.PartitionTolerance.Base.handle_startup`
function because the strategy can access the nodes from the `Cluster` module itself when needed.
- Changed `:cluster_join` -> `:post_cluster_join` and `:cluster_leave` -> `:post_cluster_leave`
- Changed `:child_migrated_hook` -> `:children_migrated_hook` and the hook data to `{node(), [child_spec()]}`
- Improved hot swap migration performance by replacing multiple single operations with bulk operations.

### Added
- Support for configurable distribution strategy. This allows the user to
switch between predefined strategies or implement their own.
- Added `ProcessHub.Strategy.Distribution.Guided` strategy which requires manual guidance
from the user to decide which nodes should be used for process distribution.
- Created guides.
- Added new hooks: `:pre_children_start_hook`, `:pre_cluster_join`, `:pre_cluster_leave`
- Documentation pages for hooks, strategies and guides.
- New API function `ProcessHub.process_list/2`

### Removed
- Reduced parameters on some strategy callbacks.
- Removed hotswap migration retention `:none` option in favour of integer value.

### Fixed
- Replication strategy `:cluster_size` option was not counting the local node.
- Tests we're failing due to race conditions in some cases.
- The hotswap migration was having difficulties with migrating large amount of processes.
- Documentation fixes.
- Process redistribution on node leave was not cleaning up the local storage properly
and some processes we're not distributed to other nodes.

## v0.1.4-alpha - 2023-11-19
Replaced :ets with Cachex for local storage to improve reliability of the system and avoid
potential race conditions.

Includes minor bugfixes and code improvements.
Introduced new hook `forwarded_migration`.

### Changed
- Increased the timeout value for children redistribution task.
- Increased integration tests load by 10x to improve the reliability of the tests.
- Replaced vanilla :ets with cachex for local storage. This improved the reliability of the system
by preventing race conditions in some scenarios.
- Increased the default process sync start timeout from 5000 -> 10000 ms.

### Added
- Added custom identifier for local storage table.
- Transactions for synchronization append function to reduce possibility of
multiple processes writing to the same table keys at the same time.
- Locking process registry when doing bulk operations to prevent overwriting of the data.
- New hook `forwarded_migration` which is called when a process is migrated to another node
and the migration is forwarded to the new node where the startup is handled.

### Fixed
- Synchronization caused multiple nodes to reply to the caller. This caused anomalies in
integration tests.
- Node up and down handlers are no longer blocking operations for coordinator to avoid
timeout errors when handling large amount of processes.
- The child start responses we're in reverse order when single child was started on multiple nodes.
- Documentation hook keys were not correct and missing the `_hook` suffix.

## v0.1.3-alpha - 2023-11-05

Fixed bugs, code improvements, added more documentation, improved tests performance by reusing peer nodes.

### Changed
- Project description.
- All integration tests start static number of nodes which will be reused
rather than start new nodes for each test case. This improved the performance
of the test suites.
- Process registry dispatches `:registry_pid_insert_hook` no longer adds the child_spec
to the hook data but rather the child_id.
- Gossip protocol synchronizes only after all the initial synchronization data is
collected from all nodes. This improves the overall efficiency of the protocol.

### Added
- Redundancy strategy for replication now supports dynamic cluster size option.
This can be used to replicate process always on all nodes.
- Examples on how to register hooks.
- WorkerQueue process who's job is to execute jobs. It is used to prevent race conditions
and execute jobs in order.

### Fixed
- Process start/stop with binary child_id returned error when used with await/1 function.
- Fixed scenario where hub was shutdown but the running tasks we're trying to call
exiting processes.
- Dynamic quorum strategy was returning wrong quorum status in some cases.
- Fixed situtation where system was caught in a locked state for a moments due to race condition in the
state handling.
- Gossip protocol interval synchronization was not always taking the data that had the highest
timestamp.

## v0.1.2-alpha - 2023-10-17

Contains minor bugfixes and improvements.

### Changed
- `ProcessHub.child_spec/1` switched static `ProcessHub` id with dynamic child id.
- Improved existing unit tests.

### Added
- Hotswap strategy provides handover callbacks using macro.

### Fixed
- Added partition mode check ups before process startup or stopping. This can prevent some errors
where node moves to partition mode before the process starts or stops.

## v0.1.1-alpha - 2023-10-07

Elixir 1.13-1.15 support added.
Includes minor bugfixes, test fixes and documentation updates.

### Added
- Added GitHub Actions for automated testing.
- Made sure that `ProcessHub` is compatible with Elixir 1.13-1.15.
- Added example usage section to the documentation.

### Changed
- Updated `ProcessHub` documentation by adding a list of all available strategies.
- Removed unnecessary file .tool-version generated by asdf.

### Fixed
- README.md table of contents links fixed.
- Fixed `ProcessHub` await/1 function example code formatting.
- Fixed tests for elixir 1.15 & OTP 26
- Fixed test case which was failing in some cases due to async call being executed before.