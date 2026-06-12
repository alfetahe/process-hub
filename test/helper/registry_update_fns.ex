defmodule Test.Helper.RegistryUpdateFns do
  @moduledoc """
  Update functions for registry propagation tests. They live in a compiled
  helper module so the closures resolve on peer nodes (mirroring real
  callers, whose update functions are defined in release modules present
  on every node).
  """

  def put_marker(value) do
    fn child_spec, node_pids, metadata ->
      {Map.put(child_spec, :marker, value), node_pids, metadata}
    end
  end
end
