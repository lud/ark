defmodule ArkReadme do
  use Readmix.Generator

  action(:plugins, params: [])

  def plugins(_, _) do
    {:ok, mods} = :application.get_key(:ark, :modules)

    plugin_mods =
      mods
      |> Enum.filter(&plugin_module?/1)
      |> Enum.sort()

    lines =
      Enum.flat_map(plugin_mods, fn mod ->
        Code.ensure_loaded!(mod)

        if function_exported?(mod, :__ark__, 1) do
          doc = mod.__ark__(:doc) |> String.trim()
          ["### `#{inspect(mod)}`\n\n#{doc}\n\n"]
        else
          IO.warn("#{inspect(mod)} does not export __ark__/1 (unpublished plugin)", [])
          []
        end
      end)

    {:ok, lines}
  end

  defp plugin_module?(mod) do
    case Module.split(mod) do
      ["Ark", _] -> true
      _ -> false
    end
  end
end
