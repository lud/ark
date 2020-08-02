defmodule Ark do
  @plugins [Ark.Ok, Ark.PipeIn, Ark.Drip]
  @plugin_docs @plugins
               |> Enum.map(fn mod -> {mod, mod.__ark__(:alias), mod.__ark__(:doc)} end)
               |> Enum.map(fn {mod, plugin_alias, plugin_doc} ->
                 """
                 ### `#{mod |> Module.split() |> Enum.join(".")}`

                 #{
                   if plugin_alias do
                     "**Alias:** `#{inspect(plugin_alias)}`"
                   else
                     "This module cannot be imported with `use Ark`"
                   end
                 }

                 #{plugin_doc}
                 """
               end)
  @moduledoc """
  Ark is a collection of small utilities useful for prototyping,
  testing, and working with Elixir common patterns.

  Each utility consists in an module that can be imported 
  through a single `use` expression.

  #### Import all Ark utilities at once:
  ```
  use Ark
  ```

  #### Import some of the Ark utilities:
  ```
  use Ark, [:ok, :pipe_in]
  ```

  #### Import utilities manually

  As utilities are mere modules, you can always import each of them
  separately:
  ```
  import Ark.Ok
  import Ark.PipeIn
  ```

  ## Utilities

  #{@plugin_docs}
  """

  @all [:pipe_in, :ok]

  defmacro __using__(opts) do
    imports =
      case List.wrap(opts) do
        [] -> @all
        list -> list
      end

    imports
    |> Enum.map(&alias_module/1)
    |> Enum.map(&abuse_module/1)
  end

  defp alias_module({:__aliases__, _, [:Ark, plugin]}), do: alias_module(:Ark, plugin)
  defp alias_module({:__aliases__, _, mod_path}), do: alias_module(Module.concat(mod_path))
  defp alias_module(:ok), do: Ark.Ok
  defp alias_module(:pipe_in), do: Ark.PipeIn

  defp alias_module(other) do
    raise "Ark plugin '#{inspect(other)}' could not be found"
  end

  defp alias_module(:Ark, :PipeIn), do: Ark.PipeIn
  defp alias_module(:Ark, :Ok), do: Ark.Ok

  defp abuse_module(mod) do
    quote do
      use unquote(mod)
    end
  end
end
