defmodule ProcessHub.Request.Handler.PidUpdateRequest do
  alias ProcessHub.Service.ProcessRegistry
  alias ProcessHub.Request.CrossNodeRequest
  alias ProcessHub.Service.HookManager
  alias ProcessHub.Constant.Hook

  defstruct [
    :child_id,
    :node,
    :pid
  ]

  def new(child_id, node, pid) do
    %__MODULE__{
      child_id: child_id,
      node: node,
      pid: pid
    }
  end

  defimpl CrossNodeRequest, for: __MODULE__ do
    alias ProcessHub.Request.Handler.PidUpdateRequest

    @impl true
    def handle(%PidUpdateRequest{child_id: child_id, node: node, pid: pid}, hub) do
      case ProcessRegistry.lookup(
             hub.hub_id,
             child_id,
             with_metadata: true
           ) do
        nil ->
          # Child not found in registry, skip update
          nil

        {cs, nodes_pids, metadata} ->
          ProcessRegistry.insert(
            hub.hub_id,
            cs,
            Keyword.put(nodes_pids, node, pid),
            metadata: metadata,
            hook_storage: hub.storage.hook
          )

          HookManager.dispatch_hook(
            hub.storage.hook,
            Hook.child_pid_updated(),
            %{node: node, pid: pid}
          )
      end
    end
  end
end
