defmodule Test.Helper.TestNode do
  @spec local_node() :: :"ex_unit@127.0.0.1"
  def local_node() do
    :"ex_unit@127.0.0.1"
  end

  def start_nodes(amount, options \\ [])
  def start_nodes(0, _), do: []

  def start_nodes(amount, options) do
    # code_paths =
    #   Enum.reduce(:code.get_path(), '', fn path, acc ->
    #     if length(path) > 0 do
    #       ' -pa ' ++ path ++ acc
    #     else
    #       acc
    #     end
    #   end)

    args = ~c"-loader inet -hosts 127.0.0.1 -setcookie \"#{:erlang.get_cookie()}\""

    nodes =
      Enum.map(1..amount, fn idx ->
        name =
          case Keyword.get(options, :prefix, nil) do
            nil -> :"#{idx}"
            prefix -> :"#{prefix}_#{idx}"
          end

        {:ok, pid, name} =
          :peer.start_link(%{
            host: ~c"127.0.0.1",
            name: name,
            args: [args]
          })

        {name, pid}
      end)

    node_names = Enum.map(nodes, fn {name, _} -> name end)

    rpc = &({_, []} = :rpc.multicall(node_names, &1, &2, &3))

    rpc.(:code, :add_paths, [:code.get_path()])

    rpc.(Application, :ensure_all_started, [:mix])
    rpc.(Application, :ensure_all_started, [:logger])

    rpc.(Logger, :configure, [[level: Logger.level()]])
    rpc.(Mix, :env, [Mix.env()])

    loaded_apps =
      for {app_name, _, _} <- Application.loaded_applications() do
        base = Application.get_all_env(app_name)

        environment =
          options
          |> Keyword.get(:environment, [])
          |> Keyword.get(app_name, [])
          |> Keyword.merge(base, fn _, v, _ -> v end)

        for {key, val} <- environment do
          rpc.(Application, :put_env, [app_name, key, val])
        end

        app_name
      end

    ordered_apps = Keyword.get(options, :applications, loaded_apps)

    for app_name <- ordered_apps, app_name in loaded_apps do
      rpc.(Application, :ensure_all_started, [app_name])
    end

    for file <- Keyword.get(options, :files, []) do
      rpc.(Code, :require_file, [file])
    end

    nodes
  end

  def stop_nodes(peer_pids) when is_list(peer_pids) do
    Enum.each(peer_pids, fn pid -> :peer.stop(pid) end)
  end

  def start_local_node() do
    {_, 0} = System.cmd("epmd", ["-daemon"])

    Node.start(local_node(), :longnames)
    # Node.set_cookie(node_name, :cookie)
  end
end
