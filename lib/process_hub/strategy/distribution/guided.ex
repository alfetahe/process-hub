defmodule ProcessHub.Strategy.Distribution.Guided do
  @moduledoc """
  Provides implementation for distribution behaviour using consistent hashing.

  This strategy expects the child mappings to be provided during process
  start-up initialization. The child mappings are used to determine the nodes and
  processes mapping.

  When processes are started using Guided distribution strategy, they will be
  bound to the nodes specified in the child mappings. If the node goes down, the
  processes won't be migrated to other nodes. They will stay on the same node
  until the node is restarted.

  Guided distribution strategy is useful when you want to have more control over
  the distribution of processes. For example, you can use it to ensure that
  processes are started on specific nodes.

  > #### Required mappings {: .warning}
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

  @type t() :: %__MODULE__{}
  defstruct []

  @spec handle_children_start(ProcessHub.hub_id(), %{
          :start_opts => keyword(),
          optional(any()) => any()
        }) ::
          :ok
  def handle_children_start(hub_id, %{start_opts: start_opts}) do
    insert_child_mappings(hub_id, Keyword.get(start_opts, :child_mapping, %{}))
  end

  @spec insert_child_mappings(ProcessHub.hub_id(), any()) :: :ok
  def insert_child_mappings(hub_id, child_mappings) do
    case Storage.get(hub_id, StorageKey.gdc()) do
      nil ->
        Storage.insert(hub_id, StorageKey.gdc(), child_mappings)

      existing_mappings ->
        new_mappings = Map.merge(existing_mappings, child_mappings)
        Storage.insert(hub_id, StorageKey.gdc(), new_mappings)
    end

    :ok
  end

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.Guided do
    alias ProcessHub.Strategy.Distribution.Guided, as: GuidedStrategy

    @impl true
    @spec children_init(struct(), ProcessHub.hub_id(), [map()], keyword()) ::
            :ok | {:error, any()}
    def children_init(_strategy, hub_id, child_specs, opts) do
      with {:ok, child_mappings} <- validate_child_init(hub_id, opts, child_specs),
           :ok <- GuidedStrategy.insert_child_mappings(hub_id, child_mappings) do
        Storage.get(hub_id, StorageKey.gdc())
        :ok
      else
        err -> err
      end
    end

    @impl true
    @spec belongs_to(
            ProcessHub.Strategy.Distribution.Guided.t(),
            ProcessHub.hub_id(),
            ProcessHub.child_id(),
            pos_integer()
          ) :: [atom]
    def belongs_to(_strategy, hub_id, child_id, replication_factor) do
      with child_mappings <- Storage.get(hub_id, StorageKey.gdc()),
           child_nodes <- Map.get(child_mappings, child_id),
           nodes <- Enum.take(child_nodes, replication_factor) do
        nodes
      else
        _ -> []
      end
    end

    @impl true
    @spec init(ProcessHub.Strategy.Distribution.Guided.t(), ProcessHub.hub_id()) :: any()
    def init(_strategy, hub_id) do
      handler = %HookManager{
        id: :guided_pre_start_handler,
        m: ProcessHub.Strategy.Distribution.Guided,
        f: :handle_children_start,
        a: [hub_id, :_]
      }

      HookManager.register_handler(hub_id, Hook.pre_children_start(), handler)
    end

    @impl true
    def handle_shutdown(_strategy, _hub_id), do: nil

    defp validate_child_init(hub_id, opts, child_specs) do
      with {:ok, mappings} <- opts_validate_existance(opts),
           :ok <- validate_mappings_type(mappings),
           :ok <- validate_children(mappings, child_specs),
           :ok <- validate_children_replication(hub_id, mappings) do
        {:ok, mappings}
      else
        err -> err
      end
    end

    defp validate_children_replication(hub_id, mappings) do
      repl_fact =
        Storage.get(hub_id, StorageKey.strred())
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
end
