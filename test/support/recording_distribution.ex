defmodule Test.Support.RecordingDistribution do
  @moduledoc """
  A distribution strategy that assigns a child to the nodes its `placement`
  table names, every other child to the local node, and tells `recorder` (when
  set) each time it is asked, so a test can read the order of a placement
  question against other events from its own mailbox. Each node holds its own
  table, so a test can make nodes disagree on where a child belongs. An `admit`
  function, when given, refuses every start while it returns `false`, as a
  strategy does whose placement target has no member yet.
  """

  alias ProcessHub.Strategy.Distribution.Base, as: DistributionStrategy

  defstruct [:recorder, :admit, placement: %{}]

  @doc "Hook handler reporting that `event` fired."
  def notify(recorder, event, _hook_data), do: send(recorder, event)

  defimpl DistributionStrategy do
    def init(strategy, _hub), do: strategy

    def belongs_to(strategy, _hub, child_ids, _replication_factor) do
      if strategy.recorder, do: send(strategy.recorder, :belongs_to)
      Map.new(child_ids, &{&1, Map.get(strategy.placement, &1, [node()])})
    end

    def children_init(%{admit: nil}, _hub, _child_specs, _opts), do: :ok

    def children_init(%{admit: admit}, _hub, _child_specs, _opts) do
      if admit.(), do: :ok, else: {:error, :not_admitted}
    end

    # Never deterministic, so a receiving node always takes the full validation.
    def deterministic?(_strategy), do: false

    def distribution_signature(_strategy, _hub), do: 0
  end
end
