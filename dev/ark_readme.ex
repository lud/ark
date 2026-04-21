defmodule ArkReadme do
  use Readmix.Generator

  action(:plugins, params: [])

  def plugins(_, _) do
    :ok = Application.ensure_loaded(:ark)
    {:ok, mods} = :application.get_key(:ark, :modules)

    sorted_mods = Enum.sort(mods)

    lines =
      Enum.flat_map(sorted_mods, fn mod ->
        Code.ensure_loaded!(mod)

        if plugin_module?(mod) do
          IO.puts("+DOC #{inspect(mod)}")
          doc = mod.__ark__(:doc) |> String.trim()
          ["### `#{inspect(mod)}`\n\n#{doc}\n\n"]
        else
          IO.puts("SKIP #{inspect(mod)}")
          []
        end
      end)

    {:ok, lines}
  end

  defp plugin_module?(mod) do
    Code.ensure_loaded!(mod)
    function_exported?(mod, :__ark__, 1)
  end
end
