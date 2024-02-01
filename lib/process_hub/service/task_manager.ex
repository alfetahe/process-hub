defmodule ProcessHub.Service.TaskManager do
  alias ProcessHub.Service.LocalStorage
  alias ProcessHub.Handler.ChildrenAdd
  alias ProcessHub.Utility.Name

  def local_reg_insert(hub_id, children) do
    Task.Supervisor.async(
      Name.task_supervisor(hub_id),
      ChildrenAdd.SyncHandle,
      :handle,
      [
        %ChildrenAdd.SyncHandle{
          hub_id: hub_id,
          children: children
        }
      ]
    )
    |> Task.await()
  end

  def start_children(hub_id, children, start_opts) do
    if length(children) > 0 do
      Task.Supervisor.start_child(
        Name.task_supervisor(hub_id),
        ChildrenAdd.StartHandle,
        :handle,
        [
          %ChildrenAdd.StartHandle{
            hub_id: hub_id,
            children: children,
            dist_sup: Name.distributed_supervisor(hub_id),
            sync_strategy: LocalStorage.get(hub_id, :synchronization_strategy),
            redun_strategy: LocalStorage.get(hub_id, :redundancy_strategy),
            dist_strategy: LocalStorage.get(hub_id, :distribution_strategy),
            start_opts: start_opts
          }
        ]
      )
    end
  end
end
