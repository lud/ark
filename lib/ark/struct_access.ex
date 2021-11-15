defmodule Ark.StructAccess do
  @doc false
  def __ark__(:doc) do
    """
    This module provides a simple way to implement the Access behaviour for any
    struct.

    ### Example

        iex> defmodule MyStruct do
        ...>   defstruct k: nil
        ...>   use Ark.StructAccess
        ...> end
        iex> s = %MyStruct{k: 1}
        iex> put_in(s.k, 2)
        %MyStruct{k: 2}
    """
  end

  @doc ~S"""
  Using this module will allow to use the access macros and functions
  (`Kernel.get_in/2`, `Kernel.put_in/2`, _etc._) with a struct.
  """
  defmacro __using__(_) do
    quote do
      @behaviour Access
      @doc false
      defdelegate fetch(term, key), to: Map
      @doc false
      defdelegate get(term, key, default), to: Map
      @doc false
      defdelegate get_and_update(term, key, fun), to: Map

      def pop(_, key) do
        raise RuntimeError, message: "cannot pop key #{key} from struct %#{__MODULE__}{}"
      end
    end
  end
end
