defprotocol ProcessHub.Strategy.Distribution.Base do
  @moduledoc """
  The distribution strategy protocol provides API functions for distributing child processes.
  """

  @callback belongs_to(
              distribution_striategy :: struct(),
              child_id :: atom() | binary(),
              replication_factor :: pos_integer()
            ) :: [atom]
  def belongs_to(strategy, child_id, replication_factor)
end
