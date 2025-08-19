defmodule ProcessHub.Strategy.Distribution.Guided do
  @moduledoc """
  Provides implementation for distribution behaviour using consistent hashing.

  This strategy expects the child mappings to be provided during process
  start-up initialization. The child mappings are used to determine the nodes and
  processes mapping.

  > #### Bounded processes {: .info}
  >
  > Guided distribution strategy does not support process migration.
  > If a node goes down, the processes will not be migrated to other nodes.
  > They are bound to the nodes specified in the child mappings.

  Guided distribution strategy is useful when you want to have more control over
  the distribution of processes. For example, you can use it to ensure that
  processes are started on specific nodes.

  > #### Required mappings {: .info}
  >
  > When using Guided distribution strategy, you **must** provide the child mappings
  > during the initialization. If the child mappings are not provided, the
  > initialization will **fail**.
  >
  > Example:
  >
  > ```elixir
  > iex> child_spec = %{id: :my_child, start: {MyProcess, :start_link, []}}
  > iex> ProcessHub.start_children(:my_hub, [child_spec], [child_mapping: %{my_child: [:node1, :node2]}])
  > ```
  """

  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy
  alias ProcessHub.Service.Storage
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Constant.StorageKey
  alias ProcessHub.Hub

  @type t() :: %__MODULE__{}
  defstruct []

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.Guided do
    alias ProcessHub.Strategy.Distribution.Guided, as: GuidedStrategy

    @impl true
    @spec init(ProcessHub.Strategy.Distribution.Guided.t(), Hub.t()) :: any()
    def init(_strategy, hub) do
      handler = %HookManager{
        id: :dg_pre_start_handler,
        m: ProcessHub.Strategy.Distribution.Guided,
        f: :handle_children_start,
        a: [hub, :_],
        p: 100
      }

      HookManager.register_handler(hub.storage.hook, Hook.pre_children_start(), handler)
    end

    @impl true
    @spec belongs_to(
            ProcessHub.Strategy.Distribution.Guided.t(),
            Hub.t(),
            ProcessHub.child_id(),
            pos_integer()
          ) :: [atom]
    def belongs_to(_strategy, hub = %Hub{}, child_id, replication_factor) do
      with %{^child_id => child_nodes} <-
             Storage.get(hub.storage.misc, StorageKey.gdc()),
           nodes <- Enum.take(child_nodes, replication_factor) do
        nodes
      else
        _ -> []
      end
    end

    @impl true
    @spec children_init(struct(), Hub.t(), [map()], keyword()) ::
            :ok | {:error, any()}
    def children_init(_strategy, hub, child_specs, opts) do
      with {:ok, child_mappings} <- validate_child_init(hub, opts, child_specs),
           :ok <- GuidedStrategy.insert_child_mappings(hub, child_mappings) do
        Storage.get(hub.storage.misc, StorageKey.gdc())
        :ok
      else
        err -> err
      end
    end

    defp validate_child_init(hub, opts, child_specs) do
      with {:ok, mappings} <- opts_validate_existance(opts),
           :ok <- validate_mappings_type(mappings),
           :ok <- validate_children(mappings, child_specs),
           :ok <- validate_children_replication(mappings, hub.storage.misc) do
        {:ok, mappings}
      else
        err -> err
      end
    end

    defp validate_children_replication(mappings, misc_storage) do
      repl_fact =
        Storage.get(misc_storage, StorageKey.strred())
        |> RedundancyStrategy.replication_factor()

      case Enum.all?(mappings, fn {_, children} -> length(children) == repl_fact end) do
        true -> :ok
        false -> {:error, :child_replication_mismatch}
      end
    end

    defp validate_mappings_type(mappings) do
      case is_map(mappings) do
        true -> :ok
        false -> {:error, :invalid_child_mapping}
      end
    end

    defp validate_children(child_mappings, child_specs) do
      child_ids = Map.keys(child_mappings)

      case Enum.all?(child_specs, fn %{id: cid} -> Enum.member?(child_ids, cid) end) do
        true -> :ok
        false -> {:error, :child_mapping_mismatch}
      end
    end

    defp opts_validate_existance(opts) do
      case Keyword.has_key?(opts, :child_mapping) do
        false -> {:error, :missing_child_mapping}
        true -> {:ok, Keyword.get(opts, :child_mapping, %{})}
      end
    end
  end

  @spec handle_children_start(Hub.t(), %{
          :start_opts => keyword(),
          optional(any()) => any()
        }) ::
          :ok
  def handle_children_start(hub, %{start_opts: start_opts}) do
    insert_child_mappings(hub, Keyword.get(start_opts, :child_mapping, %{}))
  end

  @spec insert_child_mappings(Hub.t(), any()) :: :ok
  def insert_child_mappings(hub, child_mappings) do
    misc_storage = hub.storage.misc

    case Storage.get(misc_storage, StorageKey.gdc()) do
      nil ->
        Storage.insert(misc_storage, StorageKey.gdc(), child_mappings)

      existing_mappings ->
        new_mappings = Map.merge(existing_mappings, child_mappings)
        Storage.insert(misc_storage, StorageKey.gdc(), new_mappings)
    end

    :ok
  end
end
