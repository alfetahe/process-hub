# ProcessHub Project Documentation

**Last Updated**: 2025-11-02
**Purpose**: Comprehensive reference for Claude Code when working on ProcessHub

---

## 1. Project Overview

### What is ProcessHub?

**ProcessHub** is a distributed process management library for Elixir/BEAM that provides scalable, fault-tolerant process distribution across cluster nodes.

**Core Characteristics**:
- **Eventually Consistent**: Prioritizes scalability and availability over immediate consistency
- **Asynchronous**: Most operations are non-blocking
- **Multi-Hub Support**: Run multiple independent hubs (each with unique `hub_id`)
- **Flexible Architecture**: Supports both decentralized (consistent hashing) and leader-based (centralized) distribution

**Key Features**:
1. Automatic/manual process distribution across cluster
2. Globally synchronized process registry (ETS-based, fast lookups)
3. Process monitoring with automatic restart (Supervisor)
4. Process state handover during migrations
5. 5 types of configurable strategies (12+ implementations)
6. Event-driven hook system for extensibility
7. Automatic cluster healing on node join/leave

---

## 2. Architecture & Directory Structure

### Directory Layout

```
/home/anuar/Projects/private/process-hub/
├── lib/process_hub/
│   ├── constant/              # Constants (Hook, StorageKey, Event, PriorityLevel)
│   ├── handler/               # Event handlers (ChildrenAdd, ChildrenRem, ClusterUpdate, Synchronization)
│   ├── service/               # Core services (see below)
│   ├── strategy/              # 5 strategy types (see Section 3)
│   │   ├── distribution/
│   │   ├── migration/
│   │   ├── partition_tolerance/
│   │   ├── redundancy/
│   │   └── synchronization/
│   ├── utility/               # Helper modules (Bag, Name)
│   ├── coordinator.ex         # ⭐ Heart of the system - orchestrates everything
│   ├── distributed_supervisor.ex
│   ├── initializer.ex
│   ├── janitor.ex
│   ├── worker_queue.ex
│   └── future.ex
├── test/
│   ├── helper/                # Bootstrap, Common, TestNode, TestServer
│   ├── fixture/               # Test fixtures
│   ├── strategy/              # Strategy-specific unit tests
│   └── integration_test.exs   # Main integration tests
├── guides/                    # User documentation
│   ├── Configuration.md       # ⭐ Strategy configuration reference
│   ├── Introduction.md
│   ├── Architecture.md
│   └── ...
└── CHANGELOG.md               # Version history
```

### Core Modules

#### ProcessHub (Main API)
- **Location**: `lib/process_hub.ex`
- **Purpose**: Public API - ONLY module external code should use
- **Key Functions**: `start_child/3`, `start_children/3`, `stop_child/3`, `process_list/2`, `child_lookup/2`
- **Type Spec**: Defines all valid strategy types (must update when adding new strategies)

#### ProcessHub.Coordinator
- **Location**: `lib/process_hub/coordinator.ex`
- **Purpose**: ⭐ **Heart of the system** - coordinates all events and work
- **Responsibilities**:
  - Delegates work to services or spawns handlers
  - Stores hub state (cluster nodes, configurations)
  - Handles periodic tasks (sync, propagation)
  - One coordinator process per hub

#### ProcessHub.DistributedSupervisor
- **Purpose**: Supervises distributed child processes locally
- **Behavior**: Uses Elixir `Supervisor` for monitoring/auto-restart
- **Scope**: One per hub per node

#### Service Modules (`lib/process_hub/service/`)
- **ProcessRegistry**: Fast local process lookups (ETS-based)
- **Storage**: Key-value storage abstraction (ETS-backed)
- **Cluster**: Node management and tracking
- **Distributor**: Process distribution logic
- **Synchronizer**: Registry synchronization across nodes
- **HookManager**: Hook registration and execution
- **Ring**: Hash ring operations (consistent hashing)
- **State**: Partition state management

#### Constants (`lib/process_hub/constant/`)
- **StorageKey**: ⭐ **ALWAYS USE THESE** - Never use raw atoms
  ```elixir
  # Good
  Storage.get(hub.storage.misc, StorageKey.mqms())

  # Bad
  Storage.get(hub.storage.misc, :majority_quorum_max_seen)
  ```
- **Hook**: Hook event type constants
- **Event**: Event type definitions

---

## 3. Strategy Pattern System

ProcessHub uses **Protocol-based strategies**. Each strategy type has:
1. A **Base protocol** defining the interface
2. Multiple **concrete implementations** as structs

### A. Redundancy Strategy (`ProcessHub.Strategy.Redundancy.Base`)

**Purpose**: Define replication factor and master node selection

**Protocol Interface**:
```elixir
@spec init(struct(), Hub.t()) :: struct()
@spec replication_factor(struct()) :: pos_integer()
@spec master_node(struct(), Hub.t(), child_id(), [node()]) :: node()
```

**Implementations**:

1. **Singularity** (Default)
   - **File**: `lib/process_hub/strategy/redundancy/singularity.ex`
   - **Behavior**: Single process per `child_id`, no replicas
   - **Options**: None

2. **Replication**
   - **File**: `lib/process_hub/strategy/redundancy/replication.ex`
   - **Behavior**: Multiple replicas across cluster
   - **Options**:
     - `replication_factor`: Number of replicas (default: 2) or `:cluster_size`
     - `replication_model`: `:active_active` or `:active_passive` (default: `:active_active`)
     - `redundancy_signal`: `:all`, `:active_only`, or `:none`

---

### B. Migration Strategy (`ProcessHub.Strategy.Migration.Base`)

**Purpose**: Define how processes migrate between nodes

**Protocol Interface**:
```elixir
@spec init(struct(), Hub.t()) :: struct()
@spec handle_migration(struct(), Hub.t(), node(), [child_spec()], keyword()) :: :ok
```

**Implementations**:

1. **ColdSwap** (Default)
   - **File**: `lib/process_hub/strategy/migration/cold_swap.ex`
   - **Behavior**: Stop old process before starting new one
   - **Options**: None

2. **HotSwap**
   - **File**: `lib/process_hub/strategy/migration/hot_swap.ex`
   - **Behavior**: Start new process before stopping old (zero-downtime)
   - **Features**: Supports state handover between old and new process
   - **Options**:
     - `retention`: How long to keep old process (milliseconds)
     - `handover`: Enable state handover (boolean)
     - `confirm_handover`: Wait for confirmation (boolean)

---

### C. Synchronization Strategy (`ProcessHub.Strategy.Synchronization.Base`)

**Purpose**: Define registry synchronization method across cluster

**Protocol Interface**:
```elixir
@spec init(struct(), Hub.t()) :: struct()
@spec propagate(struct(), Hub.t(), Event.registry_event_type(), term(), [node()], keyword()) :: :ok
@spec init_sync(struct(), Hub.t(), [node()]) :: :ok
@spec handle_synchronization(struct(), Hub.t(), term(), node()) :: :ok
```

**Implementations**:

1. **PubSub** (Default, Recommended)
   - **File**: `lib/process_hub/strategy/synchronization/pubsub.ex`
   - **Behavior**: Publish/subscribe model for registry changes
   - **Characteristics**: Fast, low latency, best for most use cases
   - **Options**: `sync_interval` (periodic sync interval in ms)

2. **Gossip**
   - **File**: `lib/process_hub/strategy/synchronization/gossip.ex`
   - **Behavior**: Gossip protocol for registry sync
   - **Characteristics**: Higher latency but scales better for large clusters
   - **Options**: `sync_interval`, `restricted_init`

---

### D. Partition Tolerance Strategy (`ProcessHub.Strategy.PartitionTolerance.Base`)

**Purpose**: Handle network partition detection and recovery

**Protocol Interface**:
```elixir
@spec init(struct(), Hub.t()) :: struct()
@spec toggle_lock?(struct(), Hub.t(), node()) :: boolean()
@spec toggle_unlock?(struct(), Hub.t(), node()) :: boolean()
```

**Implementations**:

1. **Divergence** (Default)
   - **File**: `lib/process_hub/strategy/partition_tolerance/divergence.ex`
   - **Behavior**: Allows cluster to diverge into subclusters during partition
   - **Recovery**: Merges back when partition heals
   - **Protection**: ❌ None (allows split-brain)
   - **Options**: None

2. **StaticQuorum**
   - **File**: `lib/process_hub/strategy/partition_tolerance/static_quorum.ex`
   - **Behavior**: Fixed minimum node count required
   - **Protection**: ✅ Split-brain protection
   - **Options**:
     - `quorum_size`: **Required** - Minimum nodes needed
     - `startup_confirm`: Check quorum at startup (default: false)
   - **Use Case**: Fixed cluster size, known node count
   - **⚠️ Warning**: Not suitable for dynamic scaling

3. **DynamicQuorum**
   - **File**: `lib/process_hub/strategy/partition_tolerance/dynamic_quorum.ex`
   - **Behavior**: Percentage-based quorum with time threshold
   - **Protection**: ⚠️ Partial (can be fooled by gradual node loss)
   - **Options**:
     - `quorum_size`: Percentage (e.g., 80 = 80%)
     - `threshold_time`: Time window for tracking (milliseconds)
   - **Use Case**: Gradual scale-down scenarios
   - **⚠️ Warning**: Scale down one node at a time within threshold_time

4. **MajorityQuorum** (Recently Added - v0.4.1)
   - **File**: `lib/process_hub/strategy/partition_tolerance/majority_quorum.ex`
   - **Behavior**: Automatic quorum based on majority of max cluster size
   - **Formula**: `floor(max_cluster_size / 2) + 1`
   - **Protection**: ✅ Split-brain protection
   - **Options**:
     - `initial_cluster_size`: Starting cluster size (default: 1)
     - `track_max_size`: Auto-track max size (default: true)
   - **Storage Key**: `StorageKey.mqms()` → `:majority_quorum_max_seen`
   - **Use Case**: ⭐ Single-node start → scale up scenarios
   - **⚠️ Warning**: Does NOT auto-handle scale-down (requires manual `reset_cluster_size/2`)
   - **API**: `ProcessHub.Strategy.PartitionTolerance.MajorityQuorum.reset_cluster_size(:hub_id, new_size)`

---

### E. Distribution Strategy (`ProcessHub.Strategy.Distribution.Base`)

**Purpose**: Determine which nodes should run which processes

**Protocol Interface**:
```elixir
@spec init(struct(), Hub.t()) :: struct()
@spec belongs_to(struct(), Hub.t(), [child_id()], pos_integer()) :: [{child_id(), [node()]}]
@spec children_init(struct(), Hub.t(), [child_spec()], keyword()) :: {:ok, [child_spec()]} | {:error, term()}
```

**Implementations**:

1. **ConsistentHashing** (Default)
   - **File**: `lib/process_hub/strategy/distribution/consistent_hashing.ex`
   - **Behavior**: Decentralized, uses hash ring
   - **Characteristics**: Even distribution, minimal rebalancing on topology changes
   - **Options**: None

2. **Guided**
   - **File**: `lib/process_hub/strategy/distribution/guided.ex`
   - **Behavior**: Manual node specification per process
   - **Usage**: Pass `child_mapping` option during startup
   - **Options**: None
   - **⚠️ Note**: Processes bound to specific nodes, no automatic migration

3. **CentralizedLoadBalancer** (Experimental)
   - **File**: `lib/process_hub/strategy/distribution/centralized_load_balancer.ex`
   - **Behavior**: Leader-based distribution using real-time metrics
   - **Characteristics**: Leader collects metrics, makes distribution decisions
   - **Options**: `push_interval` (metrics collection interval)
   - **⚠️ Warning**: Experimental, do not use in production

---

## 4. Testing Infrastructure

### Test Helpers (`test/helper/`)

#### Bootstrap (`test/helper/bootstrap.ex`)

**Purpose**: Initialize test clusters and hubs

**Key Functions**:
```elixir
# Start peer nodes using :peer module
init_nodes(nr_of_peers) :: %{peer_nodes: [{node_name, pid}]}

# Bootstrap ProcessHub on all nodes with test config
bootstrap(context) :: context

# Generate hub configuration from test context tags
gen_hub(context) :: ProcessHub.t()

# Start hubs on specified nodes with hooks
start_hubs(hub, nodes, hooks, opts) :: :ok
```

**Default Test Configuration**:
```elixir
@default_sync_interval 600_000
@default_replication_factor 2
@default_replication_model :active_passive
@default_quorum_size_static 4
@default_quorum_size_dynamic 90
@default_initial_cluster_size 1
@default_track_max_size true
```

**Strategy Builders**: Reads test tags to configure strategies
- `sync_strategy/1` - `:pubsub` or `:gossip`
- `redun_strategy/1` - `:replication` or `:singularity`
- `partition_strategy/1` - `:static`, `:dynamic`, `:majority`, or `:div`
- `distribution_strategy/1` - `:guided`, `:consistent_hashing`, or `:centralized_load_balancer`

#### Common (`test/helper/common.ex`)

**Purpose**: Shared test validation and utilities

**Validation Functions**:
```elixir
# Verify children match specs
validate_started_children(context, child_specs)

# Ensure single process per child_id (Singularity)
validate_singularity(context)

# Verify replication factor and node placement
validate_replication(context)

# Confirm registry sync across nodes
validate_sync(context)

# Check active/passive modes (Replication)
validate_redundancy_mode(context)

# Match child specs with registry
validate_registry_length(context, child_specs)
```

**Test Utilities**:
```elixir
# Start/stop children and wait for sync
sync_base_test(context, child_specs, :add | :rem, opts)

# Stop peer nodes
stop_peers(peer_nodes, count)
```

#### TestServer (`test/helper/test_server.ex`)

**Purpose**: Generic test GenServer for child processes

**Key Handlers**:
```elixir
# Handle redundancy signal from ProcessHub
handle_info({:process_hub, :redundancy_signal, mode}, state)
# Should set: Map.put(state, :redun_mode, mode)

# Get state for validation
handle_call(:get_state, _from, state)

# Set custom values for testing
handle_call({:set_value, key, value}, _from, state)
```

---

### Test Context Pattern

**ExUnit Tags Configure Test Scenarios**:

```elixir
@tag hub_id: :my_test_hub
@tag sync_strategy: :pubsub
@tag redun_strategy: :replication
@tag replication_factor: 2
@tag replication_model: :active_passive
@tag partition_strategy: :majority
@tag initial_cluster_size: 1
@tag track_max_size: true
@tag validate_metadata: true
@tag listed_hooks: [
  {Hook.post_cluster_join(), :global},
  {Hook.registry_pid_inserted(), :global},
  {Hook.registry_pid_removed(), :global}
]
test "my test", %{hub: hub} = context do
  # Test implementation
end
```

**Bootstrap reads these tags and configures the hub accordingly.**

---

### Integration Test Pattern

**Standard Structure** (`test/integration_test.exs`):

```elixir
@tag hub_id: :unique_test_name
@tag sync_strategy: :pubsub
@tag dist_strategy: :consistent_hashing
@tag validate_metadata: true
@tag listed_hooks: [{Hook.registry_pid_inserted(), :global}, ...]

test "description", %{hub_id: hub_id} = context do
  child_count = 1000
  child_specs = Bag.gen_child_specs(child_count, prefix: Atom.to_string(hub_id))

  # 1. Start children
  Common.sync_base_test(context, child_specs, :add, scope: :global)

  # 2. Validate startup
  Common.validate_registry_length(context, child_specs)
  Common.validate_started_children(context, child_specs)
  Common.validate_sync(context)

  # 3. Stop children
  Common.sync_base_test(context, child_specs, :rem, scope: :global)

  # 4. Validate cleanup
  Common.validate_sync(context)
end
```

---

### Adding New Strategy Tests

**Pattern** (based on `majority_quorum_test.exs`):

```elixir
defmodule Test.Strategy.PartitionTolerance.MyStrategyTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Strategy.PartitionTolerance.MyStrategy
  alias ProcessHub.Strategy.PartitionTolerance.Base, as: PartitionToleranceStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Constant.StorageKey

  setup do
    # Create unique hub_id and ETS storage
    hub_id = :"test_my_strategy_#{:erlang.unique_integer([:positive])}"
    misc_storage = :ets.new(hub_id, [:set, :public, :named_table])

    hub = %{
      hub_id: hub_id,
      storage: %{misc: misc_storage}
    }

    # Cleanup on exit
    on_exit(fn ->
      if :ets.whereis(hub_id) != :undefined do
        :ets.delete(hub_id)
      end
    end)

    %{hub: hub, misc_storage: misc_storage}
  end

  describe "scenario group" do
    test "specific behavior", %{hub: hub} = context do
      # Initialize cluster state
      Storage.insert(hub.storage.misc, StorageKey.hn(), [node()])

      # Initialize strategy
      strategy = %MyStrategy{option: value}
      strategy = PartitionToleranceStrategy.init(strategy, hub)

      # Test protocol functions
      assert PartitionToleranceStrategy.toggle_lock?(strategy, hub, :fake_node) === false
      assert PartitionToleranceStrategy.toggle_unlock?(strategy, hub, :fake_node) === true

      # Validate storage if strategy uses it
      assert Storage.get(hub.storage.misc, StorageKey.my_key()) == expected_value
    end
  end
end
```

---

## 5. Key Conventions

### Module Naming

1. **Strategies**: `ProcessHub.Strategy.{Type}.{Name}`
   - Example: `ProcessHub.Strategy.PartitionTolerance.MajorityQuorum`

2. **Services**: `ProcessHub.Service.{ServiceName}`
   - Example: `ProcessHub.Service.ProcessRegistry`

3. **Handlers**: `ProcessHub.Handler.{HandlerName}`
   - Example: `ProcessHub.Handler.ChildrenAdd`

4. **Constants**: `ProcessHub.Constant.{ConstantType}`
   - Example: `ProcessHub.Constant.StorageKey`

### Storage Key Patterns

**⭐ CRITICAL**: Always use `StorageKey` functions, never raw atoms

**Location**: `lib/process_hub/constant/storage_key.ex`

**Naming**: Abbreviated function names returning atoms
```elixir
def strred, do: :redundancy_strategy
def strsyn, do: :synchronization_strategy
def mqms, do: :majority_quorum_max_seen
def dqdn, do: :dynamic_quorum_down_nodes
def hr, do: :hash_ring
def hn, do: :hub_nodes
```

**Usage**:
```elixir
# ✅ Good
Storage.get(hub.storage.misc, StorageKey.mqms())

# ❌ Bad
Storage.get(hub.storage.misc, :majority_quorum_max_seen)
```

---

### Adding New Strategies - Complete Checklist

#### 1. Create Strategy Module
**File**: `lib/process_hub/strategy/{type}/{name}.ex`

```elixir
defmodule ProcessHub.Strategy.{Type}.{Name} do
  @moduledoc """
  Comprehensive documentation with:
  - What is this strategy ideal for?
  - How it works
  - Configuration example
  - Options documentation
  - Comparison with other strategies
  - Examples
  - Warnings (if applicable)
  """

  @typedoc """
  Strategy configuration.

  - `option1` - Description
  - `option2` - Description
  """
  @type t() :: %__MODULE__{
    option1: type(),
    option2: type()
  }

  @enforce_keys [:required_option]  # Only for required options
  defstruct [
    required_option: nil,
    optional_option: default_value
  ]

  # Implement protocol
  defimpl {Type}.Base, for: ProcessHub.Strategy.{Type}.{Name} do
    @impl true
    def init(strategy, hub) do
      # Initialization logic
      strategy
    end

    # Implement other protocol functions
  end
end
```

#### 2. Add Storage Keys (if needed)
**File**: `lib/process_hub/constant/storage_key.ex`

```elixir
def my_strategy_key, do: :my_strategy_storage_key
```

#### 3. Update Main ProcessHub Type Spec
**File**: `lib/process_hub.ex`

Find the `@type t()` and add your strategy to the appropriate union:
```elixir
partition_tolerance_strategy:
  ProcessHub.Strategy.PartitionTolerance.Divergence.t()
  | ProcessHub.Strategy.PartitionTolerance.StaticQuorum.t()
  | ProcessHub.Strategy.PartitionTolerance.DynamicQuorum.t()
  | ProcessHub.Strategy.PartitionTolerance.MajorityQuorum.t()
  | ProcessHub.Strategy.PartitionTolerance.{YourStrategy}.t(),  # ← ADD
```

#### 4. Add to Bootstrap Helper
**File**: `test/helper/bootstrap.ex`

Add default constants and strategy builder:
```elixir
# Add defaults
@default_your_option value

# Add to strategy builder
defp partition_strategy(context) do
  case context[:partition_strategy] do
    :your_tag ->
      %ProcessHub.Strategy.PartitionTolerance.{YourStrategy}{
        option: context[:option] || @default_your_option
      }
    # ... existing cases
  end
end
```

#### 5. Update Configuration Guide
**File**: `guides/Configuration.md`

Add to the strategy list with description:
```markdown
- `ProcessHub.Strategy.PartitionTolerance.{YourStrategy}` - this strategy provides...
  Options: `option1`, `option2`
```

Update example configuration if it's a recommended default.

#### 6. Create Tests
**File**: `test/strategy/{type}/{name}_test.exs`

Follow the pattern from Section 4 (Testing Infrastructure).

#### 7. Update CHANGELOG
**File**: `CHANGELOG.md`

Add to the current version under "Added":
```markdown
### Added
- `ProcessHub.Strategy.{Type}.{Name}` - Description of the new strategy...
```

---

### Documentation Style Guide

ProcessHub uses **special markdown boxes** for important information:

#### Info Boxes (Neutral Information)
```markdown
> #### Title {: .info}
> ProcessHub is eventually consistent. The system may not be in a consistent
> state at all times, but it will eventually converge to a consistent state.
```

#### Warning Boxes (Important Considerations)
```markdown
> #### Scaling Down Requires Manual Intervention {: .warning}
> MajorityQuorum does **not** automatically handle cluster scale-down. The
> strategy remembers the maximum cluster size to protect against split-brain.
```

#### Error/Critical Boxes (Critical Information)
```markdown
> #### Using DynamicQuorum Strategy {: .error}
> When scaling down too many nodes at once, the system may consider itself
> to be in a network partition.
```

#### Neutral Boxes
```markdown
> #### Example Usage {: .neutral}
> Configuration example here
```

**Where to Use**:
- Module `@moduledoc`
- Important sections in guides
- Configuration caveats

---

## 6. Common Patterns & Examples

### Hook Registration Pattern

```elixir
# In strategy init/2
def init(strategy, hub) do
  # Register hook
  hook = %Hook{
    id: "my_strategy_hook",
    event_type: Hook.post_cluster_join(),
    handler: fn data, hub ->
      # Handle event
      :ok
    end,
    priority: 0
  }

  HookManager.register_handlers(
    hub.storage.hook,
    Hook.post_cluster_join(),
    [hook]
  )

  strategy
end
```

### Storage Pattern

```elixir
# Always use StorageKey
alias ProcessHub.Constant.StorageKey

# Insert
Storage.insert(hub.storage.misc, StorageKey.my_key(), value)

# Get
value = Storage.get(hub.storage.misc, StorageKey.my_key())

# Get with default
value = Storage.get(hub.storage.misc, StorageKey.my_key()) || default
```

### Cluster Node Access Pattern

```elixir
alias ProcessHub.Service.Cluster

# Get all cluster nodes including local
cluster_nodes = Cluster.nodes(hub.storage.misc, [:include_local])

# Get only remote nodes
remote_nodes = Cluster.nodes(hub.storage.misc, [])

# Get node count
node_count = length(cluster_nodes)
```

---

## 7. Important Implementation Notes

### When to Lock/Unlock (Partition Strategies)

**Lock**: Enter partition mode (terminate distributed supervisor and children)
- Return `true` from `toggle_lock?/3` when quorum is lost

**Unlock**: Exit partition mode (restart distributed supervisor)
- Return `true` from `toggle_unlock?/3` when quorum is regained

### Replication Active/Passive Mode

**Signal Sending**:
- Strategies send `{:process_hub, :redundancy_signal, :active | :passive}` to processes
- Processes receive via `handle_info/2` and should store in state
- Test validation checks this state

### Migration vs Distribution

**Distribution**: Initial placement of processes on nodes
- Determined by `belongs_to/4` function
- Uses hash ring or load balancer

**Migration**: Moving processes from old to new nodes
- Triggered by topology changes (node join/leave)
- Handles state transfer (HotSwap) or simple restart (ColdSwap)

---

## 8. Recent Changes Summary

### v0.4.1-beta (In Progress)

**Added**:
- `ProcessHub.Strategy.PartitionTolerance.MajorityQuorum` - Adaptive quorum strategy
  - Tracks max cluster size, requires majority
  - Perfect for single-node → scale-up scenarios
  - Storage key: `StorageKey.mqms()` → `:majority_quorum_max_seen`
  - API: `reset_cluster_size/2` for intentional downsizing

**Fixed**:
- Replication strategy mode switching during cluster topology changes
- Test validation bug in `validate_redundancy_mode/1` (now checks for nil/missing mode)

---

## 9. Quick Reference Commands

### Run Tests
```bash
# All tests
mix test

# Integration tests only
mix test test/integration_test.exs

# Specific strategy tests
mix test test/strategy/partition_tolerance/majority_quorum_test.exs

# With trace
mix test --trace
```

### Compilation
```bash
# Compile
mix compile

# Clean build
mix clean && mix compile
```

### Documentation
```bash
# Generate docs
mix docs

# View at: doc/index.html
```

---

## 10. Project-Specific Terminology

- **Hub**: An instance of ProcessHub (identified by `hub_id`)
- **Child Spec**: Elixir supervisor child specification
- **Child ID**: Unique identifier for a process (atom or binary)
- **Replication Factor**: Number of copies of a process across cluster
- **Master Node**: Primary node for a process (in active/passive mode)
- **Quorum**: Minimum number of nodes required for cluster operation
- **Partition Mode**: State where distributed supervisor is terminated due to network partition
- **Lock/Unlock**: Enter/exit partition mode
- **Max Seen**: Maximum cluster size ever observed (MajorityQuorum)
- **Hash Ring**: Consistent hashing data structure for distribution
- **ETS**: Erlang Term Storage (fast in-memory key-value store)

---

**End of Documentation**

For the most up-to-date information, always check:
- Source code documentation (`@moduledoc`, `@doc`)
- `guides/Configuration.md` for strategy reference
- `CHANGELOG.md` for recent changes
- Test files for usage examples
