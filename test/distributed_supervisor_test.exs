defmodule Test.Service.DistributedSupervisorTest do
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Constant.Hook
  alias ProcessHub.Service.HookManager

  use ExUnit.Case

  @hub_id :distributed_supervisor_test

  setup _context do
    Test.Helper.SetupHelper.setup_base(%{}, @hub_id)
  end

  test "process self shutdown", %{hub: hub} do
    handler = Bag.recv_hook(Hook.registry_pid_removed(), self())

    HookManager.register_handler(hub.storage.hook, Hook.registry_pid_removed(), handler)

    child_spec1 = %{
      id: :self_shutdown_1,
      start: {Test.Helper.TestServer, :start_link, [%{name: :self_shutdown_1}]},
      restart: :transient
    }

    child_spec2 = %{
      id: :self_shutdown_2,
      start: {Test.Helper.TestServer, :start_link, [%{name: :self_shutdown_2}]},
      restart: :transient
    }

    ProcessHub.start_children(@hub_id, [child_spec1, child_spec2],
      async_wait: true,
      timeout: 4000
    )
    |> ProcessHub.await()

    GenServer.cast(:self_shutdown_1, {:stop, :normal})
    GenServer.cast(:self_shutdown_2, {:stop, :shutdown})

    Bag.receive_multiple(2, Hook.registry_pid_removed())

    # Make sure the child has been removed from registry
    assert ProcessHub.process_list(@hub_id, :global) === []

    # Make sure the child specification has been removed from the supervisor
    assert Supervisor.which_children(hub.managers.distributed_supervisor) === []
  end
end
