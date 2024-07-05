defmodule ProcessHub.Injector do
  defmacro __using__(opts) do
    quote do
      Module.put_attribute(__MODULE__, :base_module, unquote(opts[:base_module]))
      Module.put_attribute(__MODULE__, :overrides, unquote(opts[:override]))

      @before_compile ProcessHub.Injector
    end
  end

  defmacro __before_compile__(env) do
    base_module = Module.get_attribute(env.module, :base_module) || []
    overrides = Module.get_attribute(env.module, :overrides) || []

    exports =
      Macro.expand(base_module, __ENV__).module_info(:exports)
      |> Enum.filter(fn {func, _} -> func not in overrides end)

    for {func, arity} <- exports, func not in ~w|module_info __info__|a do
      args = for i <- 0..arity, i > 0, do: Macro.var(:"arg#{i}", __MODULE__)

      quote do
        defdelegate unquote(func)(unquote_splicing(args)), to: unquote(base_module)
      end
    end
  end
end
