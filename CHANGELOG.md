# Change Log
All notable changes to this project will be documented in this file.

## v0.3.3-alpha - YYYY-MM-DD
Includes new features, soft deprecations and unit test improvements and code refactors.

### Added
- Ability to start child processes with metadata attached to them.
- Child processes can now be started with additional metadata that will be stored in the process registry
and synced to other nodes.
- `ProcessHub.child_lookup/3` now accepts opts parameter to allow returning the metadata.
- `ProcessHub.registry_dump/1`dumps the whole process registry. Will supersede `ProcessHub.process_registry/1` in the future.
- `ProcessHub.tag_query/2` allows querying the process registry by tag. 
- `ProcessRegistry.update/3` for advanced users who want to control the process registry updates.
- Alter hooks to alter data before processing. Currently only one alter hook is available `child_data_alter_hook` which
is called right before the supervisor starts the child process. This allows the user to alter child spec, metadata or nodes list
on the same node that the process is going to be started on.

### Fixed
- Using `HotSwap` migration strategy with graceful shutdown was when no other nodes were available
causing the migration messages to be sent to `nil` node. This is now fixed and if no other nodes are available no migration
messages are sent.

### Soft Deprecations
- `ProcessHub.process_registry/1` will be deprecated in favour of `ProcessHub.registry_dump/1` due to not returning associated metadata with the processes.

## v0.3.2-alpha - 2025-04-16
Includes new feature and a breaking change. Minor improvements on documentations and other fixes.

### Breaking changes
- The process state handover has been unified for different types of migrations. Users who previously used HotSwap migration with process state handover and implemented their own custom callbacks instead of using the provided macro, will need to update their callback functions. See `ProcessHub.Strategy.Migration.HotSwap` for examples. This also removes the need to have a separate callback to handle `{:process_hub, :get_state, cid, from}` graceful shutdown migrations.

### Fixed
- Improved error handling. Single child start/stop operation error result no longer returns list.
- Fix: Prevent mix tasks from being included in production build. [https://github.com/alfetahe/process-hub/issues/10]
- Documentation typespecs and some comments.
- Minor code refactors.

### Added
- Adjusted `HookManager` documentation to allow `String.t()` as hook handler keys.
- Added new function `ProcessHub.promote_to_node/2` to handle updating the process registry after turning node node into distributed node. Useful when the node has been started as none distributed and later made into one by calling `Node.start/3` function.

## v0.3.1-alpha - 2025-02-09
New feature to self-shutdown a child process and documentation improvements.

### Added
- Added ability to self-shutdown a child process by calling returning an exit signal from the child process.
- New guide page for process starting and stopping.

### Fixed
- Minor documentation fixes.

## v0.3.0-alpha - 2025-01-08
Performance improvements, bugfixes and other minor improvements including one new feature.

### Breaking changes
- `Hook.post_children_start()` now returns: `[{child_id(), result(), pid(), [node()]}]`
- Fixed error handling on process startups and stoppings. Returning more information about the failures and partial successes. Example:`ProcessHub.start_children/3`, `ProcessHub.stop_children/3` with `async_wait: true` now on failures return: `{:error, list_of_failures(), list_of_partial_successes()}`. This does not affect successful operations.

### Added
- Added new option `on_failure: :continue | :rollback` to the `ProcessHub.start_children/3`, `ProcessHub.stop_children/3` functions. This option allows the user to specify what should happen if the operation fails.

### Fixed
- `ProcessHub.Strategy.Redundancy.Replication` was not properly updating the redundancy_signal value on some occasions
due to race condition.
- Fixed issue with `ProcessHub.Janitor` not purging the cache properly when using Gossip protocol.
- State passing on hotswap migration with graceful shutdown fixed.
- Timeout option was not properly used in some cases.

### Changed
- Improved typespecs across the codebase.
- Improved overall performance of start/stop/hotswap migration operations which involved synchronization and large
amount of message passing by using bulk operations.

## v0.2.10-alpha - 2024-11-01
Added new configuration options for timeout and other static values.

### Added
- `storage_purge_interval` option added to the configuration to allow the user to set the interval
for purging the storage table from old data (ttl based).
- `migr_base_timeout` option added to the configuration to allow the user to set the timeout
for the migration process to complete before it is considered failed.
- `dsup_max_restarts` option added to the configuration to allow the user to set the maximum
number of restarts for the distributed supervisor.
- `dsup_max_seconds` option added to the configuration to allow the user to set the maximum
number of seconds for the distributed supervisor to be running before it is considered failed.
- `dsup_shutdown_timeout` option added to the configuration to allow the user to set the timeout
for the distributed supervisor to shutdown before forcefully killing it when receiving a shutdown signal.

## v0.2.9-alpha - 2024-09-15
Bug fixes, minor documentation improvements.

### Changed
- All tests are generating binary child_id's by default instead of atoms to avoid future issues
with Keyword lists.

### Fixed
- Hotswap migration was not working properly when child_id was a binary type due to the 
`Keyword.get/3` calls.
- Cluster update was throwing errors when child_id was a binary.

### Change
- Minor documentation improvements and logging.

## v0.2.8-alpha - 2024-08-02
Minor improvements on documentation.

## v0.2.7-alpha - 2024-07-09
Removed the requirement to start the Erlang node as a distributed node as 
it is no longer needed anymore since the `blockade` library now handles only one event queue per node.
Also added ability to start child processes statically.

### Added
- Ability to start child processes statically when starting up the ProcessHub.

### Removed
- Removed the requirement to start the Erlang node as distributed node as it is no longer
needed anymore since the `blockade` library now handles only one event queue per node.

## Updated
- Hex docs from 0.30.6 -> 0.34.2

## v0.2.6-alpha - 2024-07-06
This version includes bug fixes, new API functions, and minor improvements to the documentation.

### Changed
- Replaced `Cachex` with our custom implementation to enhance performance.
- Updated the default values for `max_restarts` and `max_seconds` to 100 and 4, respectively.
- Storage module now accepts the table identifier as the first parameter, allowing
 it to be used with multiple tables.

### Added
- Introduced new API functions `get_pids/2` and `get_pid/2` to get the pid/s by `child_id`.
- New guide page for interacting with the process registry.

### Fixed
- Corrected an issue where local supervisor restarts were not properly updating the global registry.
- Fixed various typos and errors in the documentation.

## v0.2.5-alpha - 2024-06-21
Bugfixes and documentation improvements.

### Changed
- Internal hook handler ID's.

### Added
- Guide page for creating custom strategies.
- More examples on how to use the hook system.

### Fixed
- Child process stopping when `child_id` was binary type. (Reported  and fixed by [
Peaceful James](https://github.com/peaceful-james)
- Documentation errors.

## v0.2.4-alpha - 2024-06-02
This release was focused on improving the hook system and adding new features to the system.

Some of the callbacks were removed from the strategies and the hooks were introduced to replace them.
All strategies will implement the `init`callback where they can define the hooks they want to use.

### Changed
- Hooks are registered as structs with an ID so they are easier to add/remove at runtime.
- Renamed `HookManager.register_hook_handlers/3` to `HookManager.register_handlers/3`.
- `Distributor/child_terminate` now handles operation at bulk to increase efficiency.
The function is renamed to `Distributor/children_terminate`.
- All hook handlers can specify priority when registering them. Default is 0.

### Added
- Function to remove hook handler by it's ID. `HookManager.cancel_handler/3`.
- `ProcessHub.Strategy.PartitionTolerance.Base.toggle_lock?/3`
- `ProcessHub.Strategy.PartitionTolerance.Base.toggle_unlock?/3`

### Removed
- `ProcessHub.Strategy.PartitionTolerance.Base.handle_node_up/3`
- `ProcessHub.Strategy.PartitionTolerance.Base.handle_node_down/3`
- `ProcessHub.Strategy.Migration.Base.handle_process_startups/3`
- `ProcessHub.Strategy.Distribution.Base.handle_node_join/2`
- `ProcessHub.Strategy.Distribution.Base.handle_node_leave/2`
- `ProcessHub.Strategy.Distribution.Base.handle_shutdown/1`
- `ProcessHub.Strategy.Redundancy.Base.handle_post_start/3`
- `ProcessHub.Strategy.Redundancy.Base.handle_post_update/3`

### Fixed
- migration hotswap shutdown test case by synchronizing the state update.
- `Test.Helper.TestServer.handle_call/3` function parameters by adding the missin _from parameter.

## v0.2.3-alpha - 2024-04-23
Added new configuration options for timeout values and renamed LocalStorage -> Storage.

Depending on the number of nodes and processes, the default values might not be optimal.
The new timeout configuration options enable the user to fine-tune the system for their specific use case.

### Changed
- Renamed `ProcessHub.Service.LocalStorage` module to `ProcessHub.Service.Storage`.

### Added
- New timeout configuration for different operations:
    - `:hubs_discover_interval`
    - `:deadlock_recovery_timeout`
    - `:child_migration_timeout`
    - `:handover_data_wait`

## v0.2.2-alpha - 2024-03-31
This release introduces process state migration to the next node when the node is shutting down.

Note that it currently only supports the hotswap strategy with graceful shutdown of the node.

Added:
- New callback `ProcessHub.Strategy.Migration.Base.handle_startup/3` which will be
called once the processes are started on the local distributed supervisor.
- New callback `ProcessHub.Strategy.Distribution.Base.handle_shutdown/2` which will be
called when coordinator process is shutting down.
- Hotswap process state is now migrated to the next node when the node is shutting down.

Changed:
- `ProcessHub.process_list/2` when used with `local` option now returns `{child_id, pid}` tuples
and not `{child_id, [pid]}` as before.

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