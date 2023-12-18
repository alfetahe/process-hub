defprotocol ProcessHub.Strategy.Distribution.Base do
  @moduledoc """
  The distribution strategy protocol provides API functions for distributing child processes.
  """

  @callback belongs_to(
              distribution_striategy :: struct(),
              child_id :: atom() | binary(),
              hub_nodes :: [node()],
              replication_factor :: pos_integer()
            ) :: [node()]
  def belongs_to(strategy, child_id, hub_nodes, replication_factor)
end
