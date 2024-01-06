defmodule ProcessHub.Strategy.Distribution.Guided do
  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy
  alias ProcessHub.Service.LocalStorage

  @type t() :: %__MODULE__{}
  defstruct []

  defimpl DistributionStrategy, for: ProcessHub.Strategy.Distribution.Guided do
    alias ProcessHub.Strategy.Redundancy.Base, as: RedundancyStrategy

    @cache_key :guided_distribution_cache

    @impl true
    @spec children_init(struct(), atom(), [map()], keyword()) :: :ok | {:error, any()}
    def children_init(_strategy, hub_id, child_specs, opts) do
      with {:ok, child_mappings} <- validate_child_init(hub_id, opts, child_specs),
           :ok <- insert_child_mappings(hub_id, child_mappings) do
        :ok
      else
        err -> err
      end
    end

    @impl true
    @spec belongs_to(
            ProcessHub.Strategy.Distribution.Guided.t(),
            atom(),
            atom() | binary(),
            pos_integer()
          ) :: [atom]
    def belongs_to(_strategy, hub_id, child_id, replication_factor) do
      with child_mappings <- LocalStorage.get(hub_id, @cache_key),
           child_nodes <- Map.get(child_mappings, child_id),
           nodes <- Enum.take(child_nodes, replication_factor) do
        nodes
      else
        _ -> []
      end
    end

    @impl true
    def init(_strategy, _hub_id, _hub_nodes) do
    end

    @impl true
    @spec node_join(struct(), atom(), [node()], node()) :: any()
    def node_join(_strategy, _hub_id, _hub_nodes, _node) do
    end

    @impl true
    @spec node_leave(struct(), atom(), [node()], node()) :: any()
    def node_leave(_strategy, _hub_id, _hub_nodes, _node) do
    end

    defp insert_child_mappings(hub_id, child_mappings) do
      case LocalStorage.get(hub_id, @cache_key) do
        nil ->
          LocalStorage.insert(hub_id, @cache_key, child_mappings)

        existing_mappings ->
          new_mappings = Map.merge(existing_mappings, child_mappings)
          LocalStorage.insert(hub_id, @cache_key, new_mappings)

          :ok
      end
    end

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
        LocalStorage.get(hub_id, :redundancy_strategy)
        |> RedundancyStrategy.replication_factor()

      case Enum.all?(mappings, fn {_, children} -> length(children) == repl_fact end) do
        true -> :ok
        false -> {:error, :child_replication_mismatch}
      end
    end

    def validate_mappings_type(mappings) do
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
