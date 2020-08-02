defmodule Ark.PipeIn do
  defmacro __using__(_) do
    quote do
      import unquote(__MODULE__), only: [~>: 2]
    end
  end

  @doc false
  def __ark__(:alias), do: :pipe_in

  def __ark__(:doc) do
    """
    This module provides a macro to set a variable from the end of a
    pipe.
    """
  end

  defmacro expr ~> match do
    quote do
      unquote(match) = unquote(expr)
    end
  end
end
