defmodule Ark.PipeIn do
  @doc false
  defmacro __using__(_) do
    quote do
      import unquote(__MODULE__), only: [~>: 2]
    end
  end

  @doc false
  def __ark__(:doc) do
    """
    This module provides a macro to set a variable from the end of a
    pipe.

    ```
    use Ark.PipeIn

    :val
    |> Atom.to_string()
    |> String.upcase()
    ~> my_value
    ```
    """
  end

  defmacro expr ~> match do
    quote do
      unquote(match) = unquote(expr)
    end
  end
end
