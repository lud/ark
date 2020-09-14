defmodule Ark do
  @plugins [Ark.Ok, Ark.PipeIn, Ark.Drip]
  @plugin_docs @plugins
               |> Enum.map(fn mod -> {mod, mod.__ark__(:doc)} end)
               |> Enum.map(fn {mod, plugin_doc} ->
                 """
                 ### `#{mod |> Module.split() |> Enum.join(".")}`

                 #{plugin_doc}
                 """
               end)
  @moduledoc """
  Ark is a collection of small utilities useful for prototyping,
  testing, and working with Elixir common patterns.

  ## Utilities

  #{@plugin_docs}
  """
end
