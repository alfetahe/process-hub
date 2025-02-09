defmodule Test.Service.DistributedSupervisorTest do
  alias ProcessHub.Utility.Name
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager

  use ExUnit.Case

  @hub_id :distributed_supervisor_test

  setup _context do
    Test.Helper.SetupHelper.setup_base(%{}, @hub_id)
  end

  test "process self shutdown" do
    handler = Bag.recv_hook(Hook.registry_pid_removed(), self())

    HookManager.register_handler(@hub_id, Hook.registry_pid_removed(), handler)

    child_spec = %{
      id: :self_shutdown,
      start: {Test.Helper.TestServer, :start_link, [%{name: :self_shutdown}]},
      restart: :transient
    }

    ProcessHub.start_child(@hub_id, child_spec,
      async_wait: true,
      timeout: 4000
    )
    |> ProcessHub.await()

    GenServer.cast(:self_shutdown, {:stop, :normal})

    Bag.receive_multiple(1, Hook.registry_pid_removed())

    # Make sure the child has been removed from registry
    assert ProcessHub.process_list(@hub_id, :global) === []

    # Make sure the child specification has been removed from the supervisor
    assert Supervisor.which_children(Name.distributed_supervisor(@hub_id)) === []
  end
end
