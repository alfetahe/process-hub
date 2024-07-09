defmodule StartupTest do
  use ExUnit.Case

  alias ProcessHub.Utility.Bag

  test "static children startup" do
    hub_id = :static_children_startup
    child_count = 10
    child_specs = Bag.gen_child_specs(child_count, prefix: Atom.to_string(hub_id))

    ProcessHub.start_link(%ProcessHub{
      hub_id: hub_id,
      child_specs: child_specs
    })

    assert length(ProcessHub.process_list(hub_id, :global)) === child_count
  end
end
