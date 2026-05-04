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

        case check_plugin(mod) do
          :ok ->
            IO.puts("+DOC #{inspect(mod)}")
            doc = mod.__ark__(:doc) |> String.trim()
            ["### `#{inspect(mod)}`\n\n#{doc}\n\n"]

          :skip ->
            IO.puts("SKIP #{inspect(mod)}")
            []

          :missing ->
            IO.puts([IO.ANSI.yellow(), "MISSING DOCS #{inspect(mod)}", IO.ANSI.reset()])
            []
        end
      end)

    {:ok, lines}
  end

  defp check_plugin(mod) do
    case Module.split(mod) do
      ["Ark", _] ->
        Code.ensure_loaded!(mod)

        case function_exported?(mod, :__ark__, 1) do
          true -> :ok
          false -> :missing
        end

      _ ->
        :skip
    end
  end
end
